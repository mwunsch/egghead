defmodule Egghead.MCP.HTTP do
  @moduledoc """
  MCP server with HTTP transport.

  Serves the MCP JSON-RPC protocol over HTTP. Clients POST JSON-RPC
  messages to `/mcp` and receive JSON-RPC responses.

  ## Usage

      # Default port 8642
      Egghead.MCP.HTTP.start()

      # Custom port
      Egghead.MCP.HTTP.start(port: 9000)

  ## Client configuration

  For Claude Code (from any directory):

      claude mcp add --transport http egghead http://localhost:8642/mcp

  For Codex or other MCP clients, point them at `http://localhost:8642/mcp`.
  """

  use Plug.Router

  alias Egghead.MCP.Handler

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  @doc """
  Starts the HTTP MCP server. Ensures the Egghead application is started.

  ## Options

    * `:port` — port to listen on (default: 8642)
  """
  def start(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:egghead)
    port = Keyword.get(opts, :port, 8642)

    IO.puts("Egghead MCP server listening on http://localhost:#{port}/mcp")

    Bandit.start_link(plug: __MODULE__, port: port)
  end

  # POST /mcp — the MCP endpoint
  post "/mcp" do
    body = conn.body_params

    case Handler.handle(body) do
      :noreply ->
        send_resp(conn, 204, "")

      response ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))
    end
  end

  # Health check
  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok", server: "egghead"}))
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
