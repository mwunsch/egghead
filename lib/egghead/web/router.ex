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

  scope "/", Egghead.Web do
    pipe_through(:browser)

    live("/", RecordsLive)
    live("/chat", ChatLive)
  end
end
