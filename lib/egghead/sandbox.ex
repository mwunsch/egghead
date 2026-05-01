defmodule Egghead.Sandbox do
  @moduledoc """
  OS-level sandbox for agent-spawned subprocesses.

  Wraps `Port.open` with a platform-appropriate fence derived from a
  `%Egghead.Sandbox.Profile{}`. The fence is kernel-enforced — the
  `sandbox-exec(1)` profile on macOS, `bwrap(1)` arguments on Linux —
  so a subprocess (or anything it spawns) cannot touch files outside
  the profile regardless of what argv or environment it was given.

  This is the "unveil" half of egghead's pledge/unveil security model:
  the capability system declares what verbs an agent is allowed to
  perform (`Capability.check/3`), and this module confines *where*
  those verbs can have effect.

  Platform dispatch happens on `:os.type()` in `spawn_platform/4`, the
  same pattern used by the file-watcher platform split elsewhere in
  the codebase. Unsupported platforms (Windows, BSDs, illumos) log a
  one-time warning and fall through to an unsandboxed `Port.open` so
  existing workflows continue to run.

  ## Usage

      profile = Profile.from_root("/Users/mark/Work/foo", net: false)

      {:ok, port} = Sandbox.spawn(
        "/usr/bin/git",
        ["status"],
        sandbox: profile,
        cwd: "/Users/mark/Work/foo"
      )

  The caller drives the port (collects `{port, {:data, _}}` and
  `{port, {:exit_status, _}}` messages itself). The returned port is
  an ordinary Erlang port; the sandbox wrapper is invisible once
  the call has returned.
  """

  require Logger

  alias Egghead.Sandbox.Profile

  @doc """
  Spawns `executable` under the sandbox described by `opts[:sandbox]`
  (a `%Profile{}`). Returns `{:ok, port}` or `{:error, reason}`.

  Opts:

    * `:sandbox` — `%Profile{}`; if `nil`, spawns unsandboxed with a
      debug log (callers that hold external capabilities should always
      pass a profile).
    * `:cwd` — working directory for the subprocess (defaults to
      `File.cwd!/0`).
    * `:env` — list of `{key, value}` env tuples (merged onto
      inherited env).

  The subprocess is spawned with `:binary`, `:exit_status`,
  `:stderr_to_stdout`, and `:hide` — identical to the pre-sandbox
  behavior in `Tool.ProcExec`, so existing collect loops work
  unchanged.
  """
  @spec spawn(String.t(), [String.t()], keyword()) ::
          {:ok, port()} | {:error, String.t()}
  def spawn(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    cwd = opts[:cwd] || File.cwd!()
    env = Keyword.get(opts, :env, [])

    case opts[:sandbox] do
      nil ->
        Logger.debug("Sandbox.spawn: no profile supplied — running unsandboxed")
        open_port(executable, args, cwd, env)

      %Profile{} = profile ->
        with :ok <- Profile.validate(profile) do
          env = redirect_tmpdir(env, profile)
          spawn_platform(:os.type(), profile, {executable, args, cwd, env})
        end
    end
  end

  # Redirect $TMPDIR into a workspace-internal scratch dir so tools that
  # use mktemp / tempfile (git packs, editor swap files, etc.) write inside
  # the sandbox instead of needing ambient /tmp access. Respects a caller
  # that's already set TMPDIR; only creates the scratch dir when we set it.
  defp redirect_tmpdir(env, %Profile{roots: [root | _]}) do
    if List.keyfind(env, "TMPDIR", 0) do
      env
    else
      scratch = Path.join(root, ".egghead-tmp")
      _ = File.mkdir_p(scratch)
      [{"TMPDIR", scratch} | env]
    end
  end

  # Port.open's :env option REPLACES the environment rather than merging,
  # which would strip PATH and every other inherited variable. Inherit the
  # current process env and layer the caller's overrides on top so the
  # subprocess sees a complete environment.
  defp merge_env(env) do
    base = System.get_env() |> Map.to_list()
    overrides = Map.new(env)
    base |> Enum.reject(fn {k, _} -> Map.has_key?(overrides, k) end) |> Kernel.++(env)
  end

  # --- platform dispatch ---

  defp spawn_platform({:unix, :darwin}, profile, {exe, args, cwd, env}) do
    case System.find_executable("sandbox-exec") do
      nil ->
        warn_unavailable("sandbox-exec")
        open_port(exe, args, cwd, env)

      sbexec ->
        with {:ok, profile_path} <- write_profile(profile) do
          wrapped_args = ["-f", profile_path, exe | args]

          port = open_port_raw(sbexec, wrapped_args, cwd, env)
          Process.put({__MODULE__, port}, profile_path)
          {:ok, port}
        end
    end
  end

  defp spawn_platform({:unix, :linux}, profile, {exe, args, cwd, env}) do
    case System.find_executable("bwrap") do
      nil ->
        warn_bwrap_missing()
        open_port(exe, args, cwd, env)

      bwrap ->
        wrapped_args = bwrap_args(profile, cwd) ++ ["--", exe | args]
        {:ok, open_port_raw(bwrap, wrapped_args, cwd, env)}
    end
  end

  defp spawn_platform(other, _profile, {exe, args, cwd, env}) do
    warn_unsupported(other)
    open_port(exe, args, cwd, env)
  end

  # --- macOS profile generation ---

  defp write_profile(%Profile{} = profile) do
    body = macos_profile_body(profile)

    path =
      Path.join(System.tmp_dir!(), "egghead-sandbox-#{:erlang.unique_integer([:positive])}.sb")

    case File.write(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "couldn't write sandbox profile: #{inspect(reason)}"}
    end
  end

  defp macos_profile_body(%Profile{roots: roots, net: net, extra_rw: extra_rw}) do
    header = [
      "(version 1)",
      "(deny default)",
      "(allow process-fork) (allow process-exec)",
      "(allow signal (target same-sandbox))",
      "(allow mach-lookup) (allow sysctl-read)",
      "(allow file-read-metadata)",
      # System paths every executable needs — dyld, frameworks, locale.
      # The `literal` entries on intermediate path components are
      # required so the kernel can walk down into the allowed subpaths
      # when resolving e.g. /private/var/db/dyld.
      "(allow file-read*",
      ~S|  (subpath "/usr") (subpath "/bin") (subpath "/sbin")|,
      ~S|  (subpath "/System") (subpath "/Library")|,
      ~S|  (subpath "/private/var/db/dyld") (subpath "/private/var/select")|,
      ~S|  (subpath "/dev")|,
      # Intermediate path components so the kernel can walk down to
      # the allowed subpaths. Deliberately NOT including /private/etc
      # as a subpath — that would leak /etc/hosts, /etc/passwd, etc.
      ~S|  (literal "/") (literal "/private") (literal "/private/var")|,
      ~S|  (literal "/private/var/db") (literal "/private/var/folders")|,
      ~S|  (literal "/var") (literal "/var/folders")|,
      # Specific /etc files that dyld / shell / libc tooling need.
      # Everything else under /etc remains denied.
      ~S|  (literal "/etc") (literal "/private/etc")|,
      ~S|  (literal "/private/etc/localtime") (literal "/etc/localtime"))|,
      # /dev/null is inside the read-allowed /dev subpath, but write access
      # needs an explicit grant — programs routinely discard output to it.
      ~S|(allow file-write* (literal "/dev/null"))|
    ]

    rw_paths =
      (roots ++ extra_rw)
      |> Enum.flat_map(&macos_expand_firstlinks/1)
      |> Enum.uniq()

    rw_subpaths =
      for p <- rw_paths do
        ~s|  (subpath "#{escape_scheme(p)}")|
      end

    rw_block =
      ["(allow file-read* file-write*"] ++ rw_subpaths ++ [")"]

    net_block = macos_net_block(net)

    (header ++ rw_block ++ net_block) |> Enum.join("\n") |> Kernel.<>("\n")
  end

  # macOS firstlinks: /tmp -> /private/tmp, /var -> /private/var,
  # /etc -> /private/etc. sandbox-exec canonicalizes paths through
  # these before matching, so roots need both forms to cover callers
  # that pass either.
  defp macos_expand_firstlinks(path) do
    cond do
      String.starts_with?(path, "/private/") -> [path]
      String.starts_with?(path, "/tmp") -> [path, "/private" <> path]
      String.starts_with?(path, "/var") -> [path, "/private" <> path]
      String.starts_with?(path, "/etc") -> [path, "/private" <> path]
      true -> [path]
    end
  end

  defp macos_net_block(false), do: ["(deny network*)"]
  defp macos_net_block(true), do: ["(allow network*)"]

  defp macos_net_block(hosts) when is_list(hosts) do
    [
      "(allow network-outbound (remote unix-socket))",
      "(allow network-outbound (remote ip \"localhost:*\"))"
    ] ++
      Enum.map(hosts, fn h -> ~s|(allow network-outbound (remote tcp "#{h}:*"))| end) ++
      Enum.map(hosts, fn h -> ~s|(allow network-outbound (remote udp "#{h}:*"))| end)
  end

  defp escape_scheme(path), do: String.replace(path, "\"", "\\\"")

  # --- Linux bwrap argv ---

  defp bwrap_args(%Profile{roots: roots, net: net, extra_rw: extra_rw}, cwd) do
    # bwrap applies bind/tmpfs args in order. We layer:
    #   1. ro-bind the entire host root (so /usr, /bin, /lib, etc. are
    #      visible — needed for any executable to run)
    #   2. tmpfs /tmp (private scratch; redirect_tmpdir/2 also points
    #      $TMPDIR into the workspace so well-behaved tools stay there)
    #   3. tmpfs /etc, then ro-bind back only the files libc / dyld /
    #      SSL / NSS legitimately need. /etc/hosts, /etc/shadow,
    #      /etc/ssh/*, etc. stay invisible — matching the macOS
    #      sandbox-exec profile, which also masks /etc by default.
    base =
      [
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--die-with-parent",
        "--new-session",
        "--tmpfs",
        "/etc"
      ]

    # Files under /etc that real-world programs need to start at all.
    # ro-bind-try silently skips entries missing on this host (distros
    # vary — Debian has /etc/alternatives, RHEL has /etc/pki, etc.).
    etc_allowed =
      [
        "/etc/passwd",
        "/etc/group",
        "/etc/nsswitch.conf",
        "/etc/ld.so.cache",
        "/etc/ld.so.conf",
        "/etc/ld.so.conf.d",
        "/etc/localtime",
        "/etc/ssl",
        "/etc/ca-certificates",
        "/etc/pki",
        "/etc/alternatives"
      ]
      |> Enum.flat_map(fn p -> ["--ro-bind-try", p, p] end)

    # Resolver config matters only when the network is reachable; a
    # net-fenced process has no use for nameserver pointers.
    resolv =
      if net == false,
        do: [],
        else: ["--ro-bind-try", "/etc/resolv.conf", "/etc/resolv.conf"]

    rw = Enum.flat_map(roots ++ extra_rw, fn p -> ["--bind", p, p] end)

    net_args = if net == false, do: ["--unshare-net"], else: []

    chdir = ["--chdir", cwd]

    base ++ etc_allowed ++ resolv ++ rw ++ net_args ++ chdir
  end

  # --- Port open helpers ---

  defp open_port(executable, args, cwd, env) do
    case System.find_executable(executable) do
      nil -> {:error, "command not found: #{executable}"}
      resolved -> {:ok, open_port_raw(resolved, args, cwd, env)}
    end
  end

  defp open_port_raw(executable, args, cwd, env) do
    opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      {:args, args},
      {:cd, cwd}
    ]

    opts = if env == [], do: opts, else: [{:env, normalize_env(merge_env(env))} | opts]

    Port.open({:spawn_executable, executable}, opts)
  end

  # Port.open's :env option requires charlist keys+values, not binaries.
  defp normalize_env(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  # --- Warning helpers ---

  defp warn_unavailable(tool) do
    Logger.warning(
      "Egghead.Sandbox: #{tool} not found on PATH — running unsandboxed. " <>
        "Install instructions: https://egghead.example/docs/sandbox"
    )
  end

  defp warn_bwrap_missing do
    Logger.warning(
      "Egghead.Sandbox: bwrap (bubblewrap) not found on PATH — running unsandboxed. " <>
        "Install with: apt install bubblewrap / dnf install bubblewrap / pacman -S bubblewrap"
    )
  end

  defp warn_unsupported({family, name}) do
    Logger.warning(
      "Egghead.Sandbox: unsupported platform #{inspect({family, name})} — running unsandboxed."
    )
  end

  @doc """
  Cleans up the temporary sandbox profile associated with a port
  (macOS only). Called by tool collect loops after the port has
  closed. Safe to call on any platform and for ports with no profile.
  """
  @spec cleanup(port()) :: :ok
  def cleanup(port) do
    case Process.delete({__MODULE__, port}) do
      nil ->
        :ok

      path when is_binary(path) ->
        _ = File.rm(path)
        :ok
    end
  end
end
