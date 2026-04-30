import Config

# Don't auto-start the RecordStore in tests — each test starts its own.
config :egghead, :start_record_store, false
config :egghead, :start_web, false
config :egghead, :start_irc, false

# Quiet logs in tests — only warnings and errors
config :logger, level: :warning

config :egghead, Egghead.Web.Endpoint,
  server: false,
  secret_key_base:
    "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept"
