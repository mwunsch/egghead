import Config

# Path to the directory where record files live.
# Markdown (.md) and org-mode (.org) files in this directory
# are automatically loaded into the RecordStore index.
config :egghead, :records_dir, Path.expand("../records", __DIR__)

# Phoenix endpoint
config :egghead, Egghead.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  pubsub_server: Egghead.PubSub,
  live_view: [signing_salt: "egghead_lv"],
  secret_key_base:
    "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept",
  render_errors: [formats: [html: Egghead.Web.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
