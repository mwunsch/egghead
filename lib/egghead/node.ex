defmodule Egghead.Node do
  @moduledoc """
  Erlang distribution support for Egghead.

  Uses standard OTP mechanisms for node discovery:

  - **Local (same machine):** epmd (Erlang Port Mapper Daemon) registers
    named nodes automatically. `:net_adm.names()` discovers them.
    `~/.erlang.cookie` provides the shared secret. Zero config.

  - **Remote (LAN, tailnet):** the server sets `server.host` in
    `config.yml`; clients set `EGGHEAD_SERVER=host` (env var or `--server`
    CLI flag). Both sides read the same `~/.erlang.cookie`. Distribution
    travels over whatever network reaches that hostname.

  ## Routing

  `call/3` and `cast/2` transparently dispatch GenServer messages to a
  local or remote node based on whether a server connection is active.
  `server_node/0` is a `:persistent_term` read (zero-cost on the hot path).

  ## Lifecycle

  At startup, every egghead process that needs the app:
  1. Checks explicit config (or `EGGHEAD_SERVER`) for a known server.
  2. Otherwise queries epmd for a local `egghead_server` node.
  3. If found, verifies the remote version matches the local build; on
     mismatch, refuses to connect and falls back to standalone. This
     catches the case where a stale MCP server is still running from
     an earlier commit while a newer binary tries to become a client.
  4. If versions match, connects → becomes a client.
  5. If not found → starts as `egghead_server`, registers with epmd.

  ## Names

  Same-host (no `server.host` configured): the server uses **shortnames**
  and registers as `egghead_server@localhost`. The hardcoded `localhost`
  side-steps a macOS hazard where the machine's short hostname can resolve
  to a stale IP after a Wi-Fi switch.

  Cross-host (`server.host` set, or `EGGHEAD_SERVER` set on a client):
  both sides switch to **longnames** and register as
  `egghead_server@<fqdn>`. Longnames are required for cross-host
  distribution; the client mints a unique name like
  `egghead_<rand>@<fqdn>` so multiple clients can attach concurrently.
  """

  require Logger

  @persistent_term_key :egghead_server_node
  @server_name ~c"egghead_server"

  # --- Routing ---

  @doc """
  Node-aware `GenServer.call`. Routes to the server node when connected,
  otherwise calls locally.
  """
  def call(name, msg, timeout \\ 5000) do
    case server_node() do
      nil ->
        GenServer.call(name, msg, timeout)

      node ->
        try do
          GenServer.call({name, node}, msg, timeout)
        catch
          :exit, {{:nodedown, _}, _} -> exit({:disconnected, {name, msg}})
          :exit, {:noproc, _} -> exit({:disconnected, {name, msg}})
        end
    end
  end

  @doc """
  Node-aware `GenServer.cast`. Routes to the server node when connected,
  otherwise casts locally.
  """
  def cast(name, msg) do
    case server_node() do
      nil ->
        GenServer.cast(name, msg)

      node ->
        GenServer.cast({name, node}, msg)
    end
  end

  @doc "Returns the server node name, or nil if not connected."
  @spec server_node() :: node() | nil
  def server_node do
    :persistent_term.get(@persistent_term_key, nil)
  end

  @doc "Whether this process is connected to a remote server."
  @spec connected?() :: boolean()
  def connected? do
    server_node() != nil
  end

  # --- Server lifecycle ---

  @doc """
  Start the current BEAM as the Egghead server node.

  Registers with epmd automatically — no files, no custom discovery.
  Cookie comes from `~/.erlang.cookie` (OTP default).

  When `server.host` is configured, switches to longnames so other
  hosts can resolve and connect. Optionally pins the distribution
  port range via `server.port_range` so a single firewall rule
  covers it.
  """
  @spec start_server() :: :ok | {:error, term()}
  def start_server do
    {node_name, name_type} = server_node_spec(Application.get_env(:egghead, :server))

    if name_type == :longnames, do: configure_dist_port_range()
    do_start_server(node_name, name_type)
  end

  @doc """
  Compute the server's node name and `:longnames` / `:shortnames` mode
  from the configured `:server` app env. Pure; exposed for testing.
  """
  @spec server_node_spec(map() | nil) :: {atom(), :longnames | :shortnames}
  def server_node_spec(%{host: host}) when is_binary(host) and host != "" do
    {:"egghead_server@#{host}", :longnames}
  end

  def server_node_spec(_), do: {:egghead_server@localhost, :shortnames}

  defp do_start_server(node_name, name_type) do
    case Node.start(node_name, name_type) do
      {:ok, _pid} ->
        Logger.info("Egghead server node started: #{node_name}")
        :ok

      {:error, reason} ->
        Logger.warning("Could not start server node: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp configure_dist_port_range do
    case Application.get_env(:egghead, :server) do
      %{port_range: {min, max}} when is_integer(min) and is_integer(max) ->
        Application.put_env(:kernel, :inet_dist_listen_min, min)
        Application.put_env(:kernel, :inet_dist_listen_max, max)

      _ ->
        :ok
    end
  end

  # --- Client lifecycle ---

  @doc """
  Attempt to connect to a running Egghead server.

  Resolution precedence (highest first):
  1. `EGGHEAD_SERVER` env var (also set by `--server <host>` CLI flag)
  2. `server: { node:, cookie: }` config block
  3. epmd on localhost (same-host attach)

  Returns `:connected` or `:standalone`.
  """
  @spec maybe_connect() :: :connected | :standalone
  def maybe_connect do
    case discover_server() do
      {:ok, node_name, name_type} ->
        connect_to_server(node_name, name_type, configured_cookie())

      :none ->
        :standalone
    end
  end

  # Optional cookie override from explicit `server.cookie` config.
  # Falls back to `~/.erlang.cookie` (OTP default) when not set.
  defp configured_cookie do
    case Application.get_env(:egghead, :server) do
      %{cookie: cookie} when is_binary(cookie) and cookie != "" -> cookie
      _ -> nil
    end
  end

  # --- Discovery ---

  @doc false
  # Public for tests. Resolves the highest-precedence server target.
  def discover_server do
    with :none <- discover_from_env(),
         :none <- discover_from_config(),
         :none <- discover_from_epmd(~c"localhost", :shortnames) do
      :none
    end
  end

  defp discover_from_env do
    case System.get_env("EGGHEAD_SERVER") do
      nil ->
        :none

      "" ->
        :none

      host ->
        # EGGHEAD_SERVER points at a remote host. Probe epmd there;
        # if `egghead_server` is registered, return its longname.
        # Falling through to :none lets the caller drop to standalone
        # rather than hang indefinitely on an unreachable host.
        host = String.trim(host)
        discover_from_epmd(to_charlist(host), :longnames, host)
    end
  end

  defp discover_from_config do
    case Application.get_env(:egghead, :server) do
      %{node: node_str} when is_binary(node_str) ->
        {:ok, String.to_atom(node_str), name_type_for(node_str)}

      _ ->
        :none
    end
  end

  # Probe epmd at `host` for `egghead_server`. Wrapped in a Task with a
  # short timeout because `:net_adm.names/1` does a TCP connect that can
  # hang for tens of seconds against an unreachable host.
  defp discover_from_epmd(host, name_type, label \\ nil) do
    task = Task.async(fn -> :net_adm.names(host) end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, names}} ->
        case Enum.find(names, fn {name, _port} -> name == @server_name end) do
          {_name, _port} ->
            host_str = label || to_string(host)
            {:ok, :"egghead_server@#{host_str}", name_type}

          nil ->
            :none
        end

      _ ->
        :none
    end
  end

  @doc """
  Pick `:longnames` vs `:shortnames` for an explicit `node@host` string.
  A dotted host implies an FQDN and longnames; everything else
  (bare names, `@localhost`) is shortnames. Pure; exposed for testing.
  """
  @spec name_type_for(String.t()) :: :longnames | :shortnames
  def name_type_for(node_str) do
    case String.split(node_str, "@", parts: 2) do
      [_, host] -> if String.contains?(host, "."), do: :longnames, else: :shortnames
      _ -> :shortnames
    end
  end

  defp connect_to_server(node_name, name_type, cookie) do
    client_name = client_node_name(name_type)

    case Node.start(client_name, name_type) do
      {:ok, _pid} ->
        # Setting the cookie must happen *after* the local node is alive.
        # `Node.set_cookie/1` errors with "node name is not part of a
        # distributed system" otherwise.
        if cookie, do: Node.set_cookie(String.to_atom(cookie))

        if Node.connect(node_name) do
          case version_check(node_name) do
            :ok ->
              :persistent_term.put(@persistent_term_key, node_name)
              Logger.info("Connected to Egghead server: #{node_name}")
              :connected

            {:mismatch, remote, local} ->
              Logger.warning("""
              Version mismatch with Egghead server at #{node_name}:
                remote: #{remote}
                local:  #{local}
              Refusing to connect; starting standalone.

              A stale `egghead mcp` server is likely running from an
              earlier commit. Stop it (`pkill -f 'egghead mcp'`) and
              retry if you want this process to share its state.
              """)

              Node.stop()
              :standalone
          end
        else
          Logger.info("Server node #{node_name} unreachable, starting standalone")
          Node.stop()
          :standalone
        end

      {:error, _reason} ->
        Logger.info("Could not start client node, starting standalone")
        :standalone
    end
  end

  # Build a unique client node name. For shortnames (same-host), bind to
  # `localhost` for the macOS Wi-Fi reasons described in the moduledoc.
  # For longnames (cross-host), use a resolvable FQDN so the server can
  # route messages back to us.
  defp client_node_name(:shortnames) do
    :"egghead_#{:erlang.unique_integer([:positive])}@localhost"
  end

  defp client_node_name(:longnames) do
    :"egghead_#{:erlang.unique_integer([:positive])}@#{client_fqdn()}"
  end

  # Best-effort FQDN for the local host. Combines the short hostname
  # with whatever resolver domain is configured; on a tailnet with
  # MagicDNS this produces a name the server can route back to. Falls
  # back to the short name alone if no domain is configured — distribution
  # will then fail with a clear `:badhost` style error rather than hang.
  defp client_fqdn do
    {:ok, short} = :inet.gethostname()
    short = to_string(short)

    case :inet_db.res_option(:domain) do
      [] -> short
      domain when is_list(domain) and domain != [] -> "#{short}.#{domain}"
      domain when is_binary(domain) and domain != "" -> "#{short}.#{domain}"
      _ -> short
    end
  end

  # Compare our compiled `:egghead` app version against the remote's.
  # Uses `Application.spec/2` on both sides — an OTP primitive that
  # works regardless of whether the remote has any Egghead module we
  # might have renamed. RPC timeout is short: the handshake should
  # complete in milliseconds, and a slow reply is itself a red flag.
  defp version_check(node_name) do
    local = local_version()
    remote = remote_version(node_name)

    if remote == local, do: :ok, else: {:mismatch, remote, local}
  end

  defp local_version do
    case Application.spec(:egghead, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp remote_version(node_name) do
    case :rpc.call(node_name, Application, :spec, [:egghead, :vsn], 2_000) do
      {:badrpc, _} -> "unknown"
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
