defmodule Egghead.Web.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :egghead

  @session_options [
    store: :cookie,
    key: "_egghead_key",
    signing_salt: "egghead_session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])
  socket("/yjs", Egghead.Web.DocSocket, websocket: true)

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.Static,
    at: "/",
    from: {:egghead, "priv/static"},
    gzip: Mix.env() == :prod,
    only: Egghead.Web.static_paths()
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Logger)

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
