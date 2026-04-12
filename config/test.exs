import Config

# Don't auto-start the RecordStore in tests — each test starts its own.
config :egghead, :start_record_store, false
config :egghead, :start_web, false

config :egghead, Egghead.Web.Endpoint,
  server: false,
  secret_key_base:
    "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-to-accept"
