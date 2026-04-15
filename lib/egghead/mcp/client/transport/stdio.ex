defmodule Egghead.MCP.Client.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP clients.

  Spawns the configured shell command as an OS process, speaks
  line-delimited JSON-RPC over its stdin/stdout. Stderr is routed to
  `Logger.debug/1` with the server name prefix — MCP servers tend to
  log startup and health chatter on stderr.

  Mirrors the on-wire framing of `Egghead.MCP.Server` (our own stdio
  MCP *server*), so an Egghead instance can be consumed as a client
  of another Egghead via `egghead mcp`.
  """

  @behaviour Egghead.MCP.Client.Transport

  use GenServer
  require Logger

  @impl true
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def send_request(pid, envelope) do
    GenServer.call(pid, {:send, envelope})
  end

  @impl true
  def close(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- GenServer ---

  @impl true
  def init(%{command: command, owner: owner} = config) do
    name = Map.get(config, :name, "mcp")
    env = build_env(Map.get(config, :env, %{}))

    case split_command(command) do
      {:ok, exe, args} ->
        port =
          Port.open(
            {:spawn_executable, exe},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:line, 65_536},
              {:args, args},
              {:env, env}
            ]
          )

        {:ok,
         %{
           port: port,
           owner: owner,
           name: name,
           # Stderr merges into stdout under :stderr_to_stdout. We split
           # lines: JSON-RPC lines start with `{`; anything else is
           # logged as server-side chatter.
           line_buf: ""
         }}

      {:error, reason} ->
        {:stop, {:bad_command, reason}}
    end
  end

  @impl true
  def handle_call({:send, envelope}, _from, state) do
    json = Jason.encode!(envelope)
    Port.command(state.port, json <> "\n")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    full = state.line_buf <> line
    handle_line(full, state)
    {:noreply, %{state | line_buf: ""}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | line_buf: state.line_buf <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:mcp_error, {:exit_status, status}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port && Port.info(state.port),
      do: Port.close(state.port)

    :ok
  end

  # --- helpers ---

  defp handle_line("", _state), do: :ok

  defp handle_line(line, state) do
    case maybe_decode(line) do
      {:ok, envelope} ->
        send(state.owner, {:mcp_response, envelope})

      :not_json ->
        # Server-side chatter (stderr merged into stdout).
        Logger.debug("[mcp:#{state.name}] #{String.trim_trailing(line)}")
    end
  end

  defp maybe_decode(line) do
    trimmed = String.trim_leading(line)

    if String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, envelope} when is_map(envelope) -> {:ok, envelope}
        _ -> :not_json
      end
    else
      :not_json
    end
  end

  # Shell-style tokenization via OptionParser.split/1 (respects quotes,
  # so `cmd --header "authorization: Bearer X"` yields three tokens).
  # Expands `{env:VAR}` in any token before tokenization so users can
  # keep secrets out of config.yml.
  #
  # Falls back to naive whitespace split if the command isn't
  # shell-quoted (e.g. a path containing a literal `'` — rare but
  # OptionParser.split rejects it).
  defp split_command(command) when is_binary(command) do
    expanded = expand_env_refs(command)

    tokens =
      try do
        OptionParser.split(expanded)
      rescue
        _ -> String.split(expanded, ~r/\s+/, trim: true)
      end

    case tokens do
      [] ->
        {:error, :empty_command}

      [exe | args] ->
        case System.find_executable(exe) do
          nil -> {:error, {:not_found, exe}}
          path -> {:ok, path, args}
        end
    end
  end

  defp expand_env_refs(str) do
    Regex.replace(~r/\{env:([A-Z0-9_]+)\}/, str, fn _, var ->
      System.get_env(var) || ""
    end)
  end

  defp build_env(env_map) when is_map(env_map) do
    Enum.map(env_map, fn {k, v} ->
      {String.to_charlist(to_string(k)),
       v |> Egghead.Config.resolve_value() |> to_string() |> String.to_charlist()}
    end)
  end
end
