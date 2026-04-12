defmodule Egghead.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :egghead

  @session_options [
    store: :cookie,
    key: "_egghead_key",
    signing_salt: "egghead_session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/",
    from: {:egghead, "priv/static"},
    gzip: false,
    only: Egghead.Web.static_paths()
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Egghead.Web.Router)
end
