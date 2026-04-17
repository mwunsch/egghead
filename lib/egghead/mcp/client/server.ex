defmodule Egghead.MCP.Client.Server do
  @moduledoc """
  GenServer wrapping a single MCP client connection.

  Owns:
  - A `Transport` (stdio Port or HTTP conn) that frames JSON-RPC
    envelopes on the wire
  - The initialize → initialized → tools/list handshake state machine
  - A tool-list cache (populated on `tools/list` response, refreshable)
  - Pending request id → from map, for correlating replies with callers

  Registered under the server's configured `name` in
  `Egghead.MCP.Client.Registry` so other modules can address it by
  name (`MCP.Client.call_tool("exa", "web_search", %{...})`).
  """

  use GenServer
  require Logger

  alias Egghead.MCP.Client.Registry, as: MCPRegistry

  @protocol_version "2025-03-26"
  @default_call_timeout 30_000

  # --- Public ---

  def start_link(config) do
    name = Map.fetch!(config, :name)
    GenServer.start_link(__MODULE__, config, name: via(name))
  end

  @doc """
  Cached tool list (as returned by the server's `tools/list`).
  Returns `[]` if the server is still initializing or unreachable.
  """
  def tools(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.call(pid, :tools, 5_000)
      :error -> []
    end
  end

  @doc """
  Current operational status:
  - `:initializing` — handshake not yet complete
  - `:ready` — tools cached, can serve `call_tool/4`
  - `:failed` — handshake failed; supervisor will restart
  """
  def status(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.call(pid, :status, 5_000)
      :error -> :offline
    end
  end

  @doc """
  Invoke a tool. Blocks until the server replies or `opts[:timeout]`
  elapses. Returns `{:ok, text}` or `{:error, reason}`.
  """
  def call_tool(name, tool, input, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout)

    case lookup(name) do
      {:ok, pid} ->
        GenServer.call(pid, {:call_tool, tool, input}, timeout)

      :error ->
        {:error, "mcp server #{inspect(name)} is not running"}
    end
  catch
    :exit, {:timeout, _} -> {:error, "mcp call_tool timeout"}
  end

  defp via(name), do: {:via, Registry, {MCPRegistry, name}}

  defp lookup(name) do
    case Egghead.Node.server_node() do
      nil ->
        case Registry.lookup(MCPRegistry, name) do
          [{pid, _}] -> {:ok, pid}
          [] -> :error
        end

      node ->
        case :rpc.call(node, Registry, :lookup, [MCPRegistry, name]) do
          [{pid, _}] -> {:ok, pid}
          _ -> :error
        end
    end
  end

  # --- GenServer ---

  @impl true
  def init(config) do
    transport_mod = transport_module(config)

    case transport_mod.start_link(Map.put(config, :owner, self())) do
      {:ok, transport_pid} ->
        state = %{
          name: config.name,
          config: config,
          transport_mod: transport_mod,
          transport: transport_pid,
          next_id: 1,
          pending: %{},
          tools: [],
          status: :initializing
        }

        send(self(), :initialize)
        {:ok, state}

      {:error, reason} ->
        Logger.error("MCP client #{inspect(config.name)} transport failed: #{inspect(reason)}")
        {:stop, {:transport, reason}}
    end
  end

  @impl true
  def handle_call(:tools, _from, state), do: {:reply, state.tools, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:call_tool, tool, input}, from, state) do
    {id, state} = next_id(state)

    envelope = %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{name: tool, arguments: input}
    }

    :ok = state.transport_mod.send_request(state.transport, envelope)
    {:noreply, put_pending(state, id, from)}
  end

  @impl true
  def handle_info(:initialize, state) do
    {id, state} = next_id(state)

    envelope = %{
      jsonrpc: "2.0",
      id: id,
      method: "initialize",
      params: %{
        protocolVersion: @protocol_version,
        capabilities: %{},
        clientInfo: %{name: "egghead", version: to_string(Application.spec(:egghead, :vsn))}
      }
    }

    :ok = state.transport_mod.send_request(state.transport, envelope)
    {:noreply, put_pending(state, id, {:internal, :initialize})}
  end

  def handle_info({:mcp_response, envelope}, state) do
    {:noreply, route_response(envelope, state)}
  end

  def handle_info({:mcp_error, reason}, state) do
    Logger.error("MCP client #{inspect(state.name)} transport error: #{inspect(reason)}")
    # Replying :error to any pending external callers; supervisor will
    # restart us and callers can retry.
    Enum.each(state.pending, fn
      {_id, {:internal, _}} -> :ok
      {_id, from} -> GenServer.reply(from, {:error, "mcp transport error: #{inspect(reason)}"})
    end)

    {:stop, {:transport_error, reason}, %{state | pending: %{}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- internal routing ---

  defp route_response(%{"id" => id} = envelope, state) when not is_nil(id) do
    {from, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    case from do
      nil ->
        # Unknown id — drop silently (e.g. a late reply after restart).
        state

      {:internal, :initialize} ->
        handle_initialize_reply(envelope, state)

      {:internal, :tools_list} ->
        handle_tools_list_reply(envelope, state)

      external ->
        reply_call_tool(external, envelope, state)
    end
  end

  defp route_response(_envelope, state), do: state

  defp handle_initialize_reply(envelope, state) do
    case envelope do
      %{"result" => _} ->
        # Protocol requires `notifications/initialized` before anything
        # else, then we can list tools.
        :ok =
          state.transport_mod.send_request(state.transport, %{
            jsonrpc: "2.0",
            method: "notifications/initialized"
          })

        {id, state} = next_id(state)

        :ok =
          state.transport_mod.send_request(state.transport, %{
            jsonrpc: "2.0",
            id: id,
            method: "tools/list"
          })

        put_pending(state, id, {:internal, :tools_list})

      %{"error" => error} ->
        Logger.error("MCP client #{inspect(state.name)} initialize failed: #{inspect(error)}")
        %{state | status: :failed}
    end
  end

  defp handle_tools_list_reply(envelope, state) do
    case envelope do
      %{"result" => %{"tools" => tools}} when is_list(tools) ->
        %{state | tools: tools, status: :ready}

      other ->
        Logger.warning(
          "MCP client #{inspect(state.name)} tools/list unexpected reply: #{inspect(other)}"
        )

        %{state | tools: [], status: :ready}
    end
  end

  defp reply_call_tool(from, envelope, state) do
    reply =
      case envelope do
        %{"result" => %{"isError" => true, "content" => content}} ->
          {:error, content_to_text(content)}

        %{"result" => %{"content" => content}} ->
          {:ok, content_to_text(content)}

        %{"result" => result} ->
          {:ok, Jason.encode!(result)}

        %{"error" => %{"message" => msg}} ->
          {:error, "mcp error: #{msg}"}

        _ ->
          {:error, "mcp: unexpected reply shape"}
      end

    GenServer.reply(from, reply)
    state
  end

  defp content_to_text(items) when is_list(items) do
    items
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp content_to_text(other), do: inspect(other)

  # --- id/pending helpers ---

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp put_pending(state, id, from), do: %{state | pending: Map.put(state.pending, id, from)}

  defp transport_module(%{transport: :stdio}), do: Egghead.MCP.Client.Transport.Stdio
  defp transport_module(%{transport: :http}), do: Egghead.MCP.Client.Transport.Http
  defp transport_module(%{transport: "stdio"}), do: Egghead.MCP.Client.Transport.Stdio
  defp transport_module(%{transport: "http"}), do: Egghead.MCP.Client.Transport.Http
end
