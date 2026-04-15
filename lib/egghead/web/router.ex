defmodule Egghead.Web.Router do
  use Egghead.Web, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Egghead.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # Health check — no pipeline needed
  get("/health", Egghead.Web.HealthController, :check)

  # MCP JSON-RPC endpoint
  scope "/" do
    pipe_through(:api)
    post("/mcp", Egghead.Web.MCPController, :handle)
  end

  scope "/", Egghead.Web do
    pipe_through(:browser)

    live("/", AppLive)
    live("/records/*id", AppLive)
    live("/chat/:room_id", AppLive)
  end
end
