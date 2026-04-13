import Config

# Runtime configuration.
#
# Reads from ~/.config/egghead/config.yml (see Egghead.Config) with
# environment variable overrides. Env vars always win.
#
# Egghead is a personal tool. The default config is safe for
# running on your laptop (localhost, no auth, built-in secret).
# Set these env vars to expose it on a network:
#
#   SECRET_KEY_BASE   Required for networked use. Generate with:
#                     openssl rand -base64 48
#   PORT              HTTP port (default: 4000)
#   EGGHEAD_BIND      Bind address: "localhost" (default) or "0.0.0.0"
#   EGGHEAD_HOST      Public hostname for URL generation (default: "localhost")
#   EGGHEAD_RECORDS   Path to records directory
#   EGGHEAD_WEB       Set to "false" to disable the web server

# Load config file (if it exists)
file_config =
  case Egghead.Config.load() do
    {:ok, config} -> config
    _ -> %Egghead.Config{}
  end

# Records directory: env var > config file > default
records_dir =
  System.get_env("EGGHEAD_RECORDS") ||
    if file_config.records_dir, do: Path.expand(file_config.records_dir)

if records_dir do
  config :egghead, :records_dir, Path.expand(records_dir)
end

# Disable web server entirely
if System.get_env("EGGHEAD_WEB") == "false" do
  config :egghead, :start_web, false
end

# Web server configuration: env vars override config file
port =
  case System.get_env("PORT") do
    nil -> file_config.web.port
    p -> String.to_integer(p)
  end

host = System.get_env("EGGHEAD_HOST") || file_config.web.host

bind =
  case System.get_env("EGGHEAD_BIND") do
    "0.0.0.0" ->
      {0, 0, 0, 0}

    nil ->
      case file_config.web.bind do
        "0.0.0.0" -> {0, 0, 0, 0}
        _ -> {127, 0, 0, 1}
      end

    _ ->
      {127, 0, 0, 1}
  end

# If a secret key is provided, use it. Otherwise keep the
# built-in localhost-only key from config.exs.
secret_overrides =
  case System.get_env("SECRET_KEY_BASE") do
    nil ->
      if bind == {0, 0, 0, 0} do
        IO.warn("""
        WARNING: Binding to 0.0.0.0 without SECRET_KEY_BASE set.
        Your session cookies use a default key. Set SECRET_KEY_BASE
        for any network-exposed deployment:

            export SECRET_KEY_BASE=$(openssl rand -base64 48)
        """)
      end

      []

    key ->
      [secret_key_base: key]
  end

config :egghead, Egghead.Web.Endpoint, [
  {:url, [host: host, port: port]},
  {:http, [ip: bind, port: port]} | secret_overrides
]
