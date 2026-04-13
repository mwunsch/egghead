import Config

# Path to the directory where record files live.
# Markdown (.md) and org-mode (.org) files in this directory
# are automatically loaded into the RecordStore index.
# Override with EGGHEAD_RECORDS_DIR env var (see runtime.exs).
config :egghead, :records_dir, Path.expand("../records", __DIR__)

# Phoenix endpoint — safe defaults for localhost.
# runtime.exs overrides these from env vars when present.
config :egghead, Egghead.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  pubsub_server: Egghead.PubSub,
  live_view: [signing_salt: "egghead_lv"],
  secret_key_base:
    "egghead-local-dev-key-not-for-network-use-" <>
      "please-set-SECRET_KEY_BASE-if-exposing-to-network",
  render_errors: [formats: [html: Egghead.Web.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

# Logger — sane defaults, overridden per runtime mode in Application.start
config :logger, level: :info

import_config "#{config_env()}.exs"
