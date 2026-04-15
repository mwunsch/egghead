defmodule Egghead.MCP.Client.Transport.Http do
  @moduledoc """
  HTTP transport for MCP clients.

  Each JSON-RPC envelope is a `POST` to the configured URL. Single-call
  RPC only — streamable SSE is deferred. Replies are delivered back to
  the owner as `{:mcp_response, envelope}` messages.

  Headers are resolved via `Egghead.Config.resolve_value/1` so
  `Authorization: "Bearer {env:EXAMPLE_TOKEN}"` expands at send time
  without needing to reparse config.
  """

  @behaviour Egghead.MCP.Client.Transport

  use GenServer

  @impl true
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def send_request(pid, envelope) do
    GenServer.cast(pid, {:send, envelope})
  end

  @impl true
  def close(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- GenServer ---

  @impl true
  def init(%{url: url, owner: owner} = config) do
    headers =
      config
      |> Map.get(:headers, %{})
      |> Enum.map(fn {k, v} -> {to_string(k), Egghead.Config.resolve_value(v) |> to_string()} end)

    {:ok, %{url: url, owner: owner, headers: headers}}
  end

  @impl true
  def handle_cast({:send, envelope}, state) do
    owner = state.owner
    url = state.url
    headers = state.headers

    Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
      case Req.post(url, json: envelope, headers: headers, receive_timeout: 30_000) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          envelope =
            case body do
              %{} = map -> map
              str when is_binary(str) -> Jason.decode!(str)
              _ -> %{}
            end

          send(owner, {:mcp_response, envelope})

        {:ok, %{status: status, body: body}} ->
          send(owner, {:mcp_error, {:http_status, status, body}})

        {:error, reason} ->
          send(owner, {:mcp_error, {:req_error, reason}})
      end
    end)

    {:noreply, state}
  end
end
