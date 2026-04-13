defmodule Egghead.Web.MCPController do
  @moduledoc """
  HTTP transport for the MCP server.

  Delegates to `Egghead.MCP.Handler` — the same handler used by the
  stdio transport. POST JSON-RPC messages to `/mcp`.
  """

  use Egghead.Web, :controller

  alias Egghead.MCP.Handler

  def handle(conn, _params) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case Jason.decode(body) do
      {:ok, msg} ->
        case Handler.handle(msg) do
          :noreply -> send_resp(conn, 204, "")
          response -> json(conn, response)
        end

      {:error, _} ->
        conn
        |> put_status(200)
        |> json(Handler.error(nil, -32700, "Parse error"))
    end
  end
end
