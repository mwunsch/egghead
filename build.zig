const std = @import("std");

// Build script for the OpenTUI <-> Elixir NIF bridge.
//
// Driven by build_dot_zig (Hex package) which:
//   • downloads/pins Zig 0.15.1
//   • passes ERL_EI_INCLUDE_DIR (and friends) via env vars
//   • passes -Dtarget=... when zig_target is set in mix.exs
//   • passes -p priv/<target> as the install prefix
//
// We additionally take one project-specific option from
// `:zig_extra_options` in mix.exs:
//   -Dopentui_dir=PATH   directory containing libopentui.{dylib,so}
//
// At runtime the resulting bridge_nif is dlopen'd by Elixir and itself
// dlopens libopentui from the same directory via @loader_path (macOS)
// or $ORIGIN (Linux), set as an LC_RPATH below.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const erl_include = std.process.getEnvVarOwned(b.allocator, "ERL_EI_INCLUDE_DIR") catch "";
    const opentui_dir = b.option(
        []const u8,
        "opentui_dir",
        "Path to the directory containing libopentui.{dylib,so}",
    ) orelse "";

    if (erl_include.len == 0 or opentui_dir.len == 0) {
        std.debug.print(
            "note: build requires ERL_EI_INCLUDE_DIR (env) and -Dopentui_dir=PATH\n",
            .{},
        );
        return;
    }

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("native/bridge/src/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "bridge_nif",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });

    // erl_nif.h
    lib.addIncludePath(.{ .cwd_relative = erl_include });
    lib.linkLibC();

    // Link against libopentui as a sibling shared library.
    lib.addLibraryPath(.{ .cwd_relative = opentui_dir });
    lib.linkSystemLibrary("opentui");

    // Find libopentui at load time as a sibling of bridge_nif itself.
    // @loader_path is macOS, $ORIGIN is Linux. Both expand to the
    // directory of the loading binary regardless of where Burrito
    // unpacks priv/ at runtime.
    const rpath = if (target.result.os.tag == .macos) "@loader_path" else "$ORIGIN";
    lib.root_module.addRPath(.{ .cwd_relative = rpath });

    // Erlang doesn't export erl_nif symbols at link time on macOS;
    // the NIF host resolves them at load time. Tell the linker to
    // tolerate undefined symbols from references the Erlang ABI
    // pulls in.
    lib.linker_allow_shlib_undefined = true;

    // BEAM's :erlang.load_nif/2 always appends ".so" — even on macOS,
    // where the file is a Mach-O dylib. Install with that name on
    // every platform so Bridge.load_nif/0 can find it without
    // platform-specific path logic.
    const install = b.addInstallFile(lib.getEmittedBin(), "lib/libbridge_nif.so");
    b.getInstallStep().dependOn(&install.step);
}
