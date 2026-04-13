import Config

# Dev-only niceties: hot reloading, verbose errors.
# These don't apply in releases (which always build as :prod).
config :egghead, Egghead.Web.Endpoint,
  debug_errors: true,
  check_origin: false,
  code_reloader: true,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css)$",
      ~r"lib/egghead/web/.*(ex|heex)$"
    ]
  ]
