import Config

# Prod compile-time config. Minimal — runtime.exs handles the rest.
config :egghead, Egghead.Web.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Burrito launches the binary with `-noshell`, which makes Elixir default
# `IO.ANSI.enabled?/0` to false — suppressing spinners and colored output.
# Force it on; non-TTY suppression is handled per call-site (see
# `Egghead.CLI.Widgets.stdout_tty?/0`) so piped output stays clean.
config :elixir, :ansi_enabled, true
