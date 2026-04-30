defmodule Egghead.IRC.Server do
  @moduledoc """
  IRC server lifecycle: Thousand Island TCP listener wrapped in our
  own supervisor along with the connection registry.

  Started by `Egghead.Application` whenever `:start_irc` is true (which
  is the default — same shape as `:start_web`). Disable via `--no-irc`
  on `egghead serve`, `EGGHEAD_IRC=false` in the environment, or
  `config :egghead, :start_irc, false` at compile time.

  The server stores a small read-only config in `:persistent_term` at
  boot so per-connection handlers can fetch hostname / version / password
  without going through a GenServer. That config is updated only at
  start (and not changed while running), so persistent_term's
  copy-on-update tradeoff doesn't matter here.

  ## Config

      irc:
        port: 6667
        bind: 127.0.0.1
        hostname: irc.local      # optional; defaults to gethostname()
        password: "{env:EGGHEAD_IRC_PASSWORD}"   # optional shared password

  All fields are optional. With no `irc:` block, the server starts on
  127.0.0.1:6667 with no auth and a hostname derived from the local
  system. Override the port with `--irc-port` or `EGGHEAD_IRC_PORT`,
  the bind address with `EGGHEAD_IRC_BIND=0.0.0.0`.
  """

  use Supervisor

  require Logger

  alias Egghead.IRC.{Connection, Registry}

  @default_port 6667

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    irc_cfg = Keyword.fetch!(opts, :config)
    store_config(irc_cfg)

    bind = parse_bind(Map.get(irc_cfg, :bind, "127.0.0.1"))
    port = Map.get(irc_cfg, :port, @default_port)

    children = [
      Registry,
      {ThousandIsland,
       port: port, transport_options: [ip: bind], handler_module: Connection, handler_options: []}
    ]

    Logger.info("IRC server listening on #{format_addr(bind)}:#{port}")

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Read-only config snapshot for connection handlers. Stored at boot;
  callers should not mutate the returned map. Includes:

  - `:hostname` — what to use as IRC server name in prefixes / numerics
  - `:version` — egghead version string for 002/004 replies
  - `:created_at` — string for 003 RPL_CREATED
  - `:password` — `nil` if no auth, else the shared password
  """
  @spec config() :: map()
  def config do
    :persistent_term.get({__MODULE__, :config}, default_runtime_config())
  end

  defp store_config(irc_cfg) do
    hostname =
      case Map.get(irc_cfg, :hostname) do
        h when is_binary(h) and h != "" ->
          h

        _ ->
          case :inet.gethostname() do
            {:ok, name} -> List.to_string(name)
            _ -> "egghead.local"
          end
      end

    version =
      case Application.spec(:egghead, :vsn) do
        nil -> "dev"
        v -> "egghead-#{List.to_string(v)}"
      end

    cfg = %{
      hostname: hostname,
      version: version,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      password: Map.get(irc_cfg, :password)
    }

    :persistent_term.put({__MODULE__, :config}, cfg)
  end

  defp default_runtime_config do
    %{
      hostname: "egghead.local",
      version: "dev",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      password: nil
    }
  end

  defp parse_bind("0.0.0.0"), do: {0, 0, 0, 0}

  defp parse_bind(addr) when is_binary(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  defp parse_bind(_), do: {127, 0, 0, 1}

  defp format_addr({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_addr(other), do: inspect(other)
end
