import Config

# Don't auto-start the RecordStore in tests — each test starts its own.
config :egghead, :start_record_store, false
