defmodule Egghead.OpenTUIPaths do
  @moduledoc """
  Single source of truth for the OpenTUI bridge's on-disk layout.

  build_dot_zig installs Zig artifacts under
  `priv/$MIX_TARGET/lib/` (with `host` as the default subdir when
  `MIX_TARGET` is unset). The OpenTUI prebuilt download must land
  in the same dir so the bridge_nif's `@loader_path` / `$ORIGIN`
  RPATH resolves to it as a sibling.

  This module is defined inside `mix.exs` so both `MixProject`
  and `Mix.Tasks.Compile.OpentuiFetch` can call it without a
  load-order dance.
  """

  @opentui_version "v0.1.97"

  def opentui_version, do: @opentui_version

  @doc "Resolve the install dir (relative to the project root) for a target."
  def lib_dir(target) do
    Path.join(["priv", target_subdir(target), "lib"])
  end

  @doc """
  build_dot_zig installs under `priv/$MIX_TARGET/lib/`, defaulting
  to `priv/host/lib/` when `MIX_TARGET` is unset. We mirror that
  here so OpentuiFetch puts libopentui in the same directory the
  bridge_nif will be installed into, and `@loader_path` resolves.
  """
  def target_subdir(_zig_target) do
    System.get_env("MIX_TARGET", "host")
  end

  @doc """
  Map a `:zig_target` value to the OpenTUI release asset filename.

  Supports darwin-arm64, darwin-x64, linux-x64, and linux-arm64.
  Add more triples in `opentui_asset_for_triple/1` as cross-compile
  coverage extends.
  """
  def opentui_asset(:host), do: opentui_asset_for_triple(host_triple())
  def opentui_asset(triple) when is_binary(triple), do: opentui_asset_for_triple(triple)

  defp opentui_asset_for_triple(triple) do
    # Triples vary across platforms — Linux runners report
    # `x86_64-pc-linux-gnu`, macOS reports `aarch64-apple-darwin23.6.0`,
    # Zig uses `aarch64-macos`. Match arch + OS independently.
    arch = arch_of(triple)
    os = os_of(triple)

    case {arch, os} do
      {:aarch64, :darwin} -> "opentui-native-#{@opentui_version}-darwin-arm64.zip"
      {:x86_64, :darwin} -> "opentui-native-#{@opentui_version}-darwin-x64.zip"
      {:x86_64, :linux} -> "opentui-native-#{@opentui_version}-linux-x64.zip"
      {:aarch64, :linux} -> "opentui-native-#{@opentui_version}-linux-arm64.zip"
      _ -> raise "OpentuiFetch: no OpenTUI asset mapped for target #{inspect(triple)}"
    end
  end

  defp arch_of(triple) do
    cond do
      String.contains?(triple, "aarch64") -> :aarch64
      String.contains?(triple, "arm64") -> :aarch64
      String.contains?(triple, "x86_64") -> :x86_64
      true -> :unknown
    end
  end

  defp os_of(triple) do
    cond do
      String.contains?(triple, "darwin") -> :darwin
      String.contains?(triple, "macos") -> :darwin
      String.contains?(triple, "linux") -> :linux
      true -> :unknown
    end
  end

  @doc "Filename of the libopentui shared library for a target."
  def opentui_lib(:host), do: opentui_lib_for_triple(host_triple())
  def opentui_lib(triple) when is_binary(triple), do: opentui_lib_for_triple(triple)

  defp opentui_lib_for_triple(triple) do
    cond do
      matches?(triple, ["macos", "apple-darwin"]) -> "libopentui.dylib"
      matches?(triple, ["linux"]) -> "libopentui.so"
      true -> raise "OpentuiFetch: no libopentui filename for target #{inspect(triple)}"
    end
  end

  defp matches?(triple, needles) do
    Enum.any?(needles, &String.contains?(triple, &1))
  end

  defp host_triple do
    :erlang.system_info(:system_architecture) |> List.to_string()
  end
end

defmodule Mix.Tasks.Compile.OpentuiFetch do
  @moduledoc """
  Custom Mix compiler that downloads the upstream OpenTUI prebuilt
  shared library for the configured `:zig_target`.

  This is the OpenTUI-specific glue that `build_dot_zig` deliberately
  doesn't do. Everything else (Zig toolchain pin, ERL include
  detection, running `zig build`) is handled by `build_dot_zig`.
  This compiler must run *before* `:build_dot_zig` so libopentui is
  on disk when bridge_nif links against it.

  Lives in `mix.exs` (rather than `lib/mix/tasks/compile/`) so it is
  defined before the Elixir compiler runs — there's no chicken-and-egg
  with compiling our own custom compiler.
  """

  use Mix.Task.Compiler

  alias Egghead.OpenTUIPaths

  @impl true
  def run(_args) do
    target = Mix.Project.config()[:zig_target] || :host
    lib_dir = OpenTUIPaths.lib_dir(target)
    File.mkdir_p!(lib_dir)

    expected = Path.join(lib_dir, OpenTUIPaths.opentui_lib(target))

    if File.exists?(expected) and File.stat!(expected).size > 0 do
      :ok
    else
      asset = OpenTUIPaths.opentui_asset(target)

      url =
        "https://github.com/sst/opentui/releases/download/#{OpenTUIPaths.opentui_version()}/#{asset}"

      Mix.shell().info("==> downloading #{asset}")

      tmp_zip = Path.join(System.tmp_dir!(), asset)

      case System.cmd("curl", ["-fsSL", "-o", tmp_zip, url], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, status} -> Mix.raise("curl download failed (#{status}):\n#{output}")
      end

      {:ok, _} = :zip.extract(String.to_charlist(tmp_zip), [{:cwd, String.to_charlist(lib_dir)}])
      File.rm!(tmp_zip)

      unless File.exists?(expected) do
        Mix.raise("OpentuiFetch: #{expected} missing after extracting #{asset}")
      end

      Mix.shell().info("==> #{Path.basename(expected)} installed at #{expected}")
      :ok
    end
  end

  @impl true
  def clean do
    # We leave priv/<target>/ alone so the (relatively expensive)
    # prebuilt download survives `mix clean`. `rm -rf priv/<target>`
    # for a hard reset.
    :ok
  end
end

defmodule Egghead.MixProject do
  use Mix.Project

  # Set to a target triple string (e.g. "x86_64-linux-gnu") for a
  # cross-compile of the OpenTUI bridge. `:host` builds for this
  # machine. The OpentuiFetch compiler reads this same value to
  # decide which libopentui asset to download.
  @zig_target :host

  # CalVer + short git SHA. Computed at compile time:
  #   2026.4.14+61d171a  (release build from a commit)
  #   2026.4.14+dirty    (release build from a dirty tree)
  #   0.0.0+nogit        (no git available — shouldn't happen)
  #
  # Every commit produces a new version string, which is exactly what
  # Burrito needs: it keys its on-disk unpack cache on the version,
  # so a fresh version forces a clean unpack. Zero-padding is avoided
  # (2026.4.14, not 2026.04.14) so Version.parse/1 still accepts it.
  @version (case System.cmd("git", ["rev-parse", "--short=7", "HEAD"], stderr_to_stdout: true) do
              {sha, 0} ->
                {out, _} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)
                suffix = if String.trim(out) == "", do: String.trim(sha), else: "dirty"
                today = Date.utc_today()
                "#{today.year}.#{today.month}.#{today.day}+#{suffix}"

              _ ->
                "0.0.0+nogit"
            end)

  def project do
    [
      app: :egghead,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:opentui_fetch, :build_dot_zig] ++ Mix.compilers(),
      zig_target: @zig_target,
      # `:debug` here tells build_dot_zig *not* to pass -Doptimize at all.
      # That's what we want: our build.zig sets
      #   preferred_optimize_mode = .ReleaseSafe
      # so the actual build mode is still ReleaseSafe.
      #
      # Why this dance: build_dot_zig 0.7.0 emits -Doptimize=ReleaseSafe
      # (old Zig API), but Zig 0.15.1 with preferred_optimize_mode expects
      # -Drelease as a boolean flag instead. Passing the old flag makes
      # `zig build` reject it as "invalid option." Once build_dot_zig
      # updates for Zig 0.15+, this whole workaround goes away and we
      # can remove :zig_build_mode (or set it to :release_safe explicitly).
      zig_build_mode: :debug,
      zig_extra_options: [
        opentui_dir: Egghead.OpenTUIPaths.lib_dir(@zig_target)
      ],
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      releases: releases(),
      package: package(),
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Egghead",
      source_url: "https://github.com/mwunsch/egghead",
      homepage_url: "https://mwunsch.github.io/egghead/",
      formatters: ["html"],
      extras: [
        "README.md": [title: "Overview"],
        "lib/egghead/open_tui/README.md": [
          filename: "opentui_framework",
          title: "OpenTUI Framework"
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Egghead.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:build_dot_zig, "~> 0.7", runtime: false},
      {:yaml_elixir, "~> 2.11"},
      {:file_system, "~> 1.0"},
      {:earmark, "~> 1.4"},
      {:nimble_parsec, "~> 1.4"},
      {:exqlite, "~> 0.27"},
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:floki, "~> 0.36"},
      {:burrito, "~> 1.5"},
      {:y_ex, "~> 0.10"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp releases do
    [
      egghead: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            linux_x64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["AGPL-3.0-or-later"],
      links: %{}
    ]
  end
end
