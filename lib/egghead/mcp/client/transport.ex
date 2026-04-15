defmodule Egghead.MCP.Client.Transport do
  @moduledoc """
  Behaviour for MCP client transports.

  A transport is a GenServer (or GenServer-like process) that owns the
  connection to one MCP server and shuttles JSON-RPC envelopes between
  `Egghead.MCP.Client.Server` and the remote end.

  Implementations own framing/encoding; the owner process (the client
  `Server`) speaks only in decoded Elixir maps.

  ## Messages to the owner

  Transports send these to the pid that called `start_link/1`:

  - `{:mcp_response, envelope :: map()}` — a decoded JSON-RPC response
  - `{:mcp_error, reason :: term()}` — transport failure; owner should
    treat as terminal and let the supervisor restart

  ## Lifecycle

  - `start_link(config)` spawns the transport and returns `{:ok, pid}`
  - `send_request(pid, envelope)` is fire-and-forget; replies come back
    as messages to the owner
  - `close(pid)` for graceful shutdown (owner calling `Supervisor.terminate_child/2` is fine too)
  """

  @type config :: map()
  @type envelope :: map()

  @callback start_link(config) :: {:ok, pid()} | {:error, term()}
  @callback send_request(pid(), envelope) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
end
