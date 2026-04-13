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

  # Health check — no browser pipeline needed
  get("/health", Egghead.Web.HealthController, :check)

  scope "/", Egghead.Web do
    pipe_through(:browser)

    live("/", AppLive)
    live("/records/*id", AppLive)
  end
end
