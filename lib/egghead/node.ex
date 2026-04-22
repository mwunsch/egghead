defmodule Egghead.Node do
  @moduledoc """
  Erlang distribution support for Egghead.

  Uses standard OTP mechanisms for node discovery:

  - **Local (same machine):** epmd (Erlang Port Mapper Daemon) registers
    named nodes automatically. `:net_adm.names()` discovers them.
    `~/.erlang.cookie` provides the shared secret. Zero config.

  - **Remote (cross-network):** explicit `server:` section in config.yml
    provides the node name and cookie. Standard OTP approach.

  ## Routing

  `call/3` and `cast/2` transparently dispatch GenServer messages to a
  local or remote node based on whether a server connection is active.
  `server_node/0` is a `:persistent_term` read (zero-cost on the hot path).

  ## Lifecycle

  At startup, every egghead process that needs the app:
  1. Checks explicit config for a known server (user intent wins).
  2. Queries epmd for a local `egghead_server` node.
  3. If found, verifies the remote version matches the local build; on
     mismatch, refuses to connect and falls back to standalone. This
     catches the case where a stale MCP server is still running from
     an earlier commit while a newer binary tries to become a client.
  4. If versions match, connects → becomes a client.
  5. If not found → starts as `egghead_server`, registers with epmd.
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
  """
  @spec start_server() :: :ok | {:error, term()}
  def start_server do
    hostname = node_hostname()
    node_name = :"egghead_server@#{hostname}"

    case Node.start(node_name, :shortnames) do
      {:ok, _pid} ->
        Logger.info("Egghead server node started: #{node_name}")
        :ok

      {:error, reason} ->
        Logger.warning("Could not start server node: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Client lifecycle ---

  @doc """
  Attempt to connect to a running Egghead server.

  Checks explicit `server:` config first (user intent wins), then
  queries epmd for a local `egghead_server` node. Returns `:connected`
  or `:standalone`.
  """
  @spec maybe_connect() :: :connected | :standalone
  def maybe_connect do
    case discover_server() do
      {:ok, node_name} ->
        connect_to_server(node_name)

      :none ->
        :standalone
    end
  end

  # --- Discovery ---

  defp discover_server do
    case discover_from_config() do
      {:ok, _} = found -> found
      :none -> discover_from_epmd()
    end
  end

  defp discover_from_config do
    case Application.get_env(:egghead, :server) do
      %{node: node_str, cookie: cookie_str}
      when is_binary(node_str) and is_binary(cookie_str) ->
        # Set cookie explicitly for remote connections
        Node.set_cookie(String.to_atom(cookie_str))
        {:ok, String.to_atom(node_str)}

      %{node: node_str} when is_binary(node_str) ->
        {:ok, String.to_atom(node_str)}

      _ ->
        :none
    end
  end

  defp discover_from_epmd do
    # Query epmd via loopback explicitly. The no-arg `:net_adm.names/0`
    # defaults to the machine's short hostname, which on macOS can resolve
    # to a stale IP after a Wi-Fi change and block the TCP connect for
    # tens of seconds. `localhost` always resolves from /etc/hosts.
    case :net_adm.names(~c"localhost") do
      {:ok, names} ->
        case Enum.find(names, fn {name, _port} -> name == @server_name end) do
          {_name, _port} ->
            {:ok, :"egghead_server@#{node_hostname()}"}

          nil ->
            :none
        end

      {:error, _} ->
        :none
    end
  end

  defp connect_to_server(node_name) do
    hostname = node_hostname()
    client_name = :"egghead_#{:erlang.unique_integer([:positive])}@#{hostname}"

    case Node.start(client_name, :shortnames) do
      {:ok, _pid} ->
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

  # Always use "localhost" for the shortnames suffix so the node name
  # is stable across network changes. `:inet.gethostname/0` returns the
  # machine's short name (e.g. "MacBookPro"), which macOS may resolve
  # to a stale IP after a Wi-Fi switch — any peer that tries to connect
  # by that name will then stall on the TCP SYN.
  defp node_hostname, do: "localhost"
end
