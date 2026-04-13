import Config

# Prod compile-time config. Minimal — runtime.exs handles the rest.
config :egghead, Egghead.Web.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
