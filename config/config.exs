import Config

# Phoenix endpoint — compile-time defaults only.
# Runtime config (port, host, bind, records_dir) is applied in
# Egghead.Application.start/2 from ~/.config/egghead/config.yml
# and environment variables. No runtime.exs.
config :egghead, Egghead.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: true,
  pubsub_server: Egghead.PubSub,
  live_view: [signing_salt: "egghead_lv"],
  secret_key_base:
    "egghead-local-dev-key-not-for-network-use-" <>
      "please-set-SECRET_KEY_BASE-if-exposing-to-network",
  render_errors: [formats: [html: Egghead.Web.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason
config :logger, level: :info

import_config "#{config_env()}.exs"
