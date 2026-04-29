defmodule Egghead.NodeTest do
  @moduledoc """
  Unit tests for `Egghead.Node` discovery, name selection, and config
  parsing. The cross-host integration test uses `:peer` to spawn a real
  named BEAM and verifies the discover → connect handshake without
  needing two physical machines.
  """

  use ExUnit.Case, async: false

  alias Egghead.Config
  alias Egghead.Node, as: ENode

  setup do
    # Save and restore distribution-relevant globals around each test.
    saved_server = Application.get_env(:egghead, :server)
    saved_egghead_server = System.get_env("EGGHEAD_SERVER")

    on_exit(fn ->
      if saved_server do
        Application.put_env(:egghead, :server, saved_server)
      else
        Application.delete_env(:egghead, :server)
      end

      if saved_egghead_server do
        System.put_env("EGGHEAD_SERVER", saved_egghead_server)
      else
        System.delete_env("EGGHEAD_SERVER")
      end
    end)

    Application.delete_env(:egghead, :server)
    System.delete_env("EGGHEAD_SERVER")
    :ok
  end

  describe "server_node_spec/1" do
    test "no config → shortname @localhost" do
      assert {:egghead_server@localhost, :shortnames} = ENode.server_node_spec(nil)
    end

    test "empty server map → shortname @localhost" do
      assert {:egghead_server@localhost, :shortnames} = ENode.server_node_spec(%{})
    end

    test "server.host set → longname with that host" do
      assert {:"egghead_server@orca.tailnet.ts.net", :longnames} =
               ENode.server_node_spec(%{host: "orca.tailnet.ts.net"})
    end

    test "server.host empty string → falls back to localhost shortname" do
      assert {:egghead_server@localhost, :shortnames} =
               ENode.server_node_spec(%{host: ""})
    end
  end

  describe "name_type_for/1" do
    test "FQDN host → longnames" do
      assert ENode.name_type_for("egghead_server@orca.tailnet.ts.net") == :longnames
    end

    test "@localhost → shortnames" do
      assert ENode.name_type_for("egghead_server@localhost") == :shortnames
    end

    test "bare hostname (no dot) → shortnames" do
      assert ENode.name_type_for("egghead_server@orca") == :shortnames
    end

    test "missing @ → shortnames" do
      assert ENode.name_type_for("egghead_server") == :shortnames
    end
  end

  describe "Config.parse_server (via Config.load)" do
    setup do
      tmp =
        System.tmp_dir!() |> Path.join("egghead-node-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      System.put_env("EGGHEAD_CONFIG", Path.join(tmp, "config.yml"))

      on_exit(fn ->
        System.delete_env("EGGHEAD_CONFIG")
        File.rm_rf(tmp)
      end)

      {:ok, dir: tmp}
    end

    test "parses server.host", %{dir: dir} do
      File.write!(Path.join(dir, "config.yml"), """
      server:
        host: orca.tailnet.ts.net
      """)

      {:ok, config} = Config.load()
      assert config.server == %{host: "orca.tailnet.ts.net"}
    end

    test "parses server.port_range as a tuple", %{dir: dir} do
      File.write!(Path.join(dir, "config.yml"), """
      server:
        host: orca.tailnet.ts.net
        port_range: [9100, 9105]
      """)

      {:ok, config} = Config.load()
      assert config.server == %{host: "orca.tailnet.ts.net", port_range: {9100, 9105}}
    end

    test "still parses legacy server.node + server.cookie", %{dir: dir} do
      File.write!(Path.join(dir, "config.yml"), """
      server:
        node: egghead_server@somewhere.lan
        cookie: shared-secret
      """)

      {:ok, config} = Config.load()
      assert config.server[:node] == "egghead_server@somewhere.lan"
      assert config.server[:cookie] == "shared-secret"
    end

    test "empty server block → nil", %{dir: dir} do
      File.write!(Path.join(dir, "config.yml"), """
      server: {}
      """)

      {:ok, config} = Config.load()
      assert config.server == nil
    end

    test "rejects malformed port_range", %{dir: dir} do
      File.write!(Path.join(dir, "config.yml"), """
      server:
        host: foo.bar
        port_range: [9100]
      """)

      {:ok, config} = Config.load()
      # Invalid port_range silently dropped; host preserved.
      assert config.server == %{host: "foo.bar"}
    end
  end

  describe "discover_server/0 precedence" do
    test "EGGHEAD_SERVER pointing at unreachable host returns :none within timeout" do
      System.put_env("EGGHEAD_SERVER", "egghead-test-nonexistent.invalid")

      # The timeout in discover_from_epmd is 2s. Allow some slack.
      {time_us, result} = :timer.tc(fn -> ENode.discover_server() end)

      assert result == :none
      assert time_us < 5_000_000, "discover_server hung for #{div(time_us, 1000)}ms"
    end

    test "explicit server.node config wins over local epmd lookup" do
      Application.put_env(:egghead, :server, %{
        node: "egghead_server@some.fqdn.lan",
        cookie: "test-cookie"
      })

      assert {:ok, :"egghead_server@some.fqdn.lan", :longnames} = ENode.discover_server()
    end

    test "no env, no config, no local server → :none" do
      # Skip if a real egghead_server is already registered with epmd
      # (e.g. dev box has `egghead serve` running). The test would still
      # pass in that case but for the wrong reason — we'd be testing the
      # epmd path, not the empty-state fallback.
      case :net_adm.names(~c"localhost") do
        {:ok, names} ->
          if Enum.any?(names, fn {name, _} -> name == ~c"egghead_server" end) do
            :ok
          else
            assert ENode.discover_server() == :none
          end

        _ ->
          assert ENode.discover_server() == :none
      end
    end
  end

  # Spawn a peer BEAM, register it as `egghead_server@localhost` with
  # epmd, and verify that `discover_server/0` finds it. This exercises
  # the same discover → epmd-probe path that runs cross-host, just on a
  # single machine.
  #
  # Tagged `:integration` because it needs the test BEAM in distributed
  # mode, which interferes with any concurrently running `egghead serve`.
  # Run with `mix test --include integration`.
  describe "discover_server/0 with a real peer (integration)" do
    @describetag :integration

    setup do
      case :net_kernel.start([:egghead_test_master@localhost, :shortnames]) do
        {:ok, _} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          {:skip, "could not start :net_kernel: #{inspect(reason)}"}
      end
    end

    test "finds egghead_server registered with epmd" do
      {:ok, peer, _node} =
        :peer.start_link(%{name: ~c"egghead_server", host: ~c"localhost", longnames: false})

      try do
        assert {:ok, :egghead_server@localhost, :shortnames} = ENode.discover_server()
      after
        :peer.stop(peer)
      end
    end
  end
end
