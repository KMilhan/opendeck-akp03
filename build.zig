const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const mirajazz_mod = b.createModule(.{
        .root_source_file = b.path("../mirajazz/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("mirajazz", mirajazz_mod);

    const exe = b.addExecutable(.{
        .name = "opendeck-akp03",
        .root_module = root_module,
    });

    exe.addIncludePath(.{ .cwd_relative = "../mirajazz/third_party" });
    exe.addCSourceFile(.{ .file = b.path("../mirajazz/src/c/stb_image_write.c"), .flags = &.{} });

    const hidapi_include = b.option([]const u8, "hidapi-include", "Path to hidapi headers") orelse "";
    if (hidapi_include.len != 0) {
        exe.addIncludePath(.{ .cwd_relative = hidapi_include });
    }

    const os_tag = target.result.os.tag;
    const hidapi_lib = b.option([]const u8, "hidapi-lib", "hidapi library name") orelse switch (os_tag) {
        .linux => "hidapi-hidraw",
        .macos => "hidapi",
        .windows => "hidapi",
        else => "hidapi",
    };
    exe.linkSystemLibrary(hidapi_lib);

    const turbojpeg_enabled = b.option(bool, "turbojpeg", "Link turbojpeg for JPEG pipeline") orelse true;
    if (turbojpeg_enabled) {
        const turbojpeg_lib = b.option([]const u8, "turbojpeg-lib", "turbojpeg library name") orelse "turbojpeg";
        exe.linkSystemLibrary(turbojpeg_lib);
    }

    const system_lib_dir = b.option([]const u8, "system-lib-dir", "Additional system library directory") orelse "";
    if (system_lib_dir.len != 0) {
        exe.addLibraryPath(.{ .cwd_relative = system_lib_dir });
    }

    if (os_tag == .linux and
        target.result.os.tag == builtin.os.tag and
        target.result.cpu.arch == builtin.cpu.arch)
    {
        exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        exe.addLibraryPath(.{ .cwd_relative = "/lib" });
        exe.addLibraryPath(.{ .cwd_relative = "/usr/lib64" });
        exe.addLibraryPath(.{ .cwd_relative = "/lib64" });
    }

    switch (os_tag) {
        .macos => {
            exe.linkFramework("IOKit");
            exe.linkFramework("CoreFoundation");
        },
        .windows => {
            exe.linkSystemLibrary("setupapi");
        },
        else => {},
    }

    b.installArtifact(exe);

    const package_host_only = b.option(bool, "package-host-only", "Only require host platform binaries when packaging") orelse false;
    const need_linux = (!package_host_only or target.result.os.tag == .linux);
    const need_macos = (!package_host_only or target.result.os.tag == .macos);
    const need_windows = (!package_host_only or target.result.os.tag == .windows);

    const package_step = b.step("package", "Assemble sdPlugin directory and zip");
    package_step.dependOn(b.getInstallStep());
    const script =
        "set -euo pipefail\n" ++
        "id=st.lynx.plugins.opendeck-akp03.sdPlugin\n" ++
        "pick_bin() {\n" ++
        "  for p in \"$@\"; do\n" ++
        "    if [ -f \"$p\" ]; then\n" ++
        "      printf '%s' \"$p\"\n" ++
        "      return 0\n" ++
        "    fi\n" ++
        "  done\n" ++
        "  return 1\n" ++
        "}\n" ++
        "linux_bin=\"\"\n" ++
        "mac_bin=\"\"\n" ++
        "win_bin=\"\"\n" ++
        "if ! linux_bin=$(pick_bin target/plugin-linux/bin/opendeck-akp03 target/plugin-linux/x86_64-unknown-linux-gnu/release/opendeck-akp03 zig-out/bin/opendeck-akp03); then\n" ++
        "  if [ \"${NEED_LINUX}\" = \"1\" ]; then\n" ++
        "    echo \"missing Linux binary (run: zig build -Doptimize=ReleaseFast -p target/plugin-linux)\" >&2\n" ++
        "    exit 1\n" ++
        "  fi\n" ++
        "  echo \"warning: skipping Linux binary\" >&2\n" ++
        "fi\n" ++
        "if ! mac_bin=$(pick_bin target/plugin-mac/bin/opendeck-akp03 target/plugin-mac/universal2-apple-darwin/release/opendeck-akp03 target/plugin-mac/x86_64-apple-darwin/release/opendeck-akp03 zig-out/bin/opendeck-akp03); then\n" ++
        "  if [ \"${NEED_MACOS}\" = \"1\" ]; then\n" ++
        "    echo \"missing macOS binary (run: just build-mac)\" >&2\n" ++
        "    exit 1\n" ++
        "  fi\n" ++
        "  echo \"warning: skipping macOS binary\" >&2\n" ++
        "fi\n" ++
        "if ! win_bin=$(pick_bin target/plugin-win/bin/opendeck-akp03.exe target/plugin-win/x86_64-pc-windows-gnu/release/opendeck-akp03.exe zig-out/bin/opendeck-akp03.exe); then\n" ++
        "  if [ \"${NEED_WINDOWS}\" = \"1\" ]; then\n" ++
        "    echo \"missing Windows binary (run: zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -p target/plugin-win)\" >&2\n" ++
        "    exit 1\n" ++
        "  fi\n" ++
        "  echo \"warning: skipping Windows binary\" >&2\n" ++
        "fi\n" ++
        "rm -rf build\n" ++
        "mkdir -p build/${id}\n" ++
        "cp -r assets build/${id}\n" ++
        "cp manifest.json build/${id}\n" ++
        "if [ -n \"$linux_bin\" ]; then\n" ++
        "  cp \"$linux_bin\" build/${id}/opendeck-akp03-linux\n" ++
        "fi\n" ++
        "if [ -n \"$mac_bin\" ]; then\n" ++
        "  cp \"$mac_bin\" build/${id}/opendeck-akp03-mac\n" ++
        "fi\n" ++
        "if [ -n \"$win_bin\" ]; then\n" ++
        "  cp \"$win_bin\" build/${id}/opendeck-akp03-win.exe\n" ++
        "fi\n" ++
        "(cd build && zip -r opendeck-akp03.plugin.zip ${id}/)\n";
    const package_cmd = b.addSystemCommand(&.{ "sh", "-lc", script });
    package_cmd.setEnvironmentVariable("NEED_LINUX", if (need_linux) "1" else "0");
    package_cmd.setEnvironmentVariable("NEED_MACOS", if (need_macos) "1" else "0");
    package_cmd.setEnvironmentVariable("NEED_WINDOWS", if (need_windows) "1" else "0");
    package_step.dependOn(&package_cmd.step);
}
