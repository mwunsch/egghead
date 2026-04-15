import Config

# Logger stays at :info in dev — Phoenix's debug-level chatter
# (per-event `HANDLE EVENT`, `Replied in Nµs`, live-reload pings)
# drowns out actual app logs otherwise. LiveView's per-event log
# is additionally suppressed via `log: false` on `use Phoenix.LiveView`
# in `Egghead.Web.live_view/0`.
config :logger, level: :info

# Dev-only niceties: hot reloading, verbose errors.
# These don't apply in releases (which always build as :prod).
config :egghead, Egghead.Web.Endpoint,
  debug_errors: true,
  check_origin: false,
  code_reloader: true,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css)$"E,
      ~r"lib/egghead/web/.*(ex|heex)$"E
    ]
  ]
