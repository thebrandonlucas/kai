const std = @import("std");

const RocTarget = struct {
    name: []const u8,
    query: std.Target.Query,
};

const roc_targets = [_]RocTarget{
    .{
        .name = "x64musl",
        .query = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .musl,
        },
    },
    .{
        .name = "arm64musl",
        .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .musl,
        },
    },
    .{
        .name = "x64mac",
        .query = .{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
        },
    },
    .{
        .name = "arm64mac",
        .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
        },
    },
};

pub fn build(b: *std.Build) void {
    // e.g. ReleaseSafe, ReleaseFast, ReleaseSmall, Debug
    const optimize = b.standardOptimizeOption(.{});

    const hosts_step = b.step(
        "hosts",
        "Build the Roc host libraries for all supported targets.",
    );
    for (roc_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.query);

        const host_lib = b.addLibrary(.{
            .name = b.fmt("host-{s}", .{roc_target.name}),
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/host.zig"),
                .target = target,
                .optimize = optimize,
                .strip = optimize != .Debug,
                .pic = true,
            }),
        });

        host_lib.bundle_compiler_rt = true;

        const copy_host = b.addUpdateSourceFiles();
        copy_host.addCopyFileToSource(
            host_lib.getEmittedBin(),
            b.fmt(
                "platform/targets/{s}/libhost.a",
                .{roc_target.name},
            ),
        );

        copy_host.step.dependOn(&host_lib.step);
        hosts_step.dependOn(&copy_host.step);
    }

    b.getInstallStep().dependOn(hosts_step);

    // All static checks (roc, zig, sh)
    const check_step = b.step(
        "check",
        "Run formatting and static checks",
    );
    const zig_fmt = b.addSystemCommand(&.{
        "zig", "fmt", "--check", "build.zig", "src",
    });
    check_step.dependOn(&zig_fmt.step);

    const sh_fmt = b.addSystemCommand(&.{
        "shfmt",
        "-d",
        "scripts",
    });
    check_step.dependOn(&sh_fmt.step);

    const check_scripts = b.addSystemCommand(&.{
        "shellcheck",
        "scripts/build-release.sh",
        "scripts/bundle-platform.sh",
        "scripts/check-kai-composition.sh",
    });
    check_step.dependOn(&check_scripts.step);

    const check_blueprint = b.addSystemCommand(&.{
        "roc", "check", "platform/blueprint/package.roc",
    });
    check_step.dependOn(&check_blueprint.step);

    const check_platform = b.addSystemCommand(&.{
        "roc", "check", "platform/main.roc",
    });
    check_step.dependOn(&check_platform.step);

    const check_kai = b.addSystemCommand(&.{
        "scripts/check-kai-composition.sh",
        ".",
        "kai.shell.default.nix",
    });
    check_step.dependOn(&check_kai.step);

    const check_cli = b.addSystemCommand(&.{
        "roc", "check", "cli/main.roc",
    });
    check_step.dependOn(&check_cli.step);

    const check_blueprint_example = b.addSystemCommand(&.{
        "roc", "check", "examples/blueprint-nix-cowsay/main.roc",
    });
    check_step.dependOn(&check_blueprint_example.step);

    const check_cowsay = b.addSystemCommand(&.{
        "roc", "check", "examples/kai-nix-cowsay/main.roc",
    });
    check_step.dependOn(&check_cowsay.step);

    // Mutating format step. Convenience for devs who don't have
    // editor config for roc, zig, nix, and sh all setup.
    //
    // Not used in CI -- CI only does static checks.
    const fmt_step = b.step("fmt", "Format all source code files.");

    const zig_fmt_write = b.addSystemCommand(&.{
        "zig",
        "fmt",
        "build.zig",
        "src",
    });
    fmt_step.dependOn(&zig_fmt_write.step);

    const sh_fmt_write = b.addSystemCommand(&.{
        "shfmt",
        "-w",
        "scripts",
    });
    fmt_step.dependOn(&sh_fmt_write.step);

    const nix_fmt_write = b.addSystemCommand(&.{
        "nix",
        "fmt",
        "flake.nix",
    });
    fmt_step.dependOn(&nix_fmt_write.step);

    const test_step = b.step(
        "test",
        "Run checks and Roc tests.",
    );
    test_step.dependOn(check_step);

    // Format every Roc source and test every discovered Zig source and Roc
    // root without maintaining file lists in build.zig.
    addDiscoveredSourceSteps(
        b,
        fmt_step,
        test_step,
        check_step,
        optimize,
    );

    const ci_step = b.step(
        "ci",
        "Run tests and build representative applications",
    );
    ci_step.dependOn(test_step);

    // Avoid shell redirection or mkdir inside a script.
    const prepare_outputs = b.addSystemCommand(&.{
        "mkdir", "-p", "zig-out/bin", "zig-out/tests",
    });
    prepare_outputs.step.dependOn(test_step);
    prepare_outputs.step.dependOn(hosts_step);

    const build_cli = b.addSystemCommand(&.{
        "roc",
        "build",
        "cli/main.roc",
        "--opt=dev",
        "--output=zig-out/bin/kai",
    });
    build_cli.step.dependOn(&prepare_outputs.step);
    ci_step.dependOn(&build_cli.step);

    const build_cowsay = b.addSystemCommand(&.{
        "roc",
        "build",
        "examples/kai-nix-cowsay/main.roc",
        "--opt=dev",
        "--output=zig-out/bin/kai-config",
    });
    build_cowsay.step.dependOn(&prepare_outputs.step);
    ci_step.dependOn(&build_cowsay.step);

    const bundle_platform = b.addSystemCommand(&.{
        "scripts/bundle-platform.sh",
    });
    // Ensure the release host library exists before bundling
    bundle_platform.step.dependOn(hosts_step);

    const bundle_step = b.step(
        "bundle",
        "Build the Kai platform bundle",
    );
    bundle_step.dependOn(&bundle_platform.step);
}

fn addDiscoveredSourceSteps(
    b: *std.Build,
    fmt_step: *std.Build.Step,
    test_step: *std.Build.Step,
    check_step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
) void {
    const io = b.graph.io;
    var root = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch @panic("failed to open project directory for test discovery");
    defer root.close(io);

    var walker = root.walkSelectively(b.allocator) catch
        @panic("failed to initialize test discovery");

    defer walker.deinit();

    const native_target = b.resolveTargetQuery(.{});

    while (walker.next(io) catch @panic("failed while discovering tests")) |entry| {
        if (entry.kind == .directory) {
            if (!isIgnoredTestDirectory(entry.basename)) {
                walker.enter(io, entry) catch
                    @panic("failed to enter directory during test discovery");
            }
            continue;
        }

        if (entry.kind != .file) continue;

        if (std.mem.endsWith(u8, entry.path, ".zig")) {
            const path = b.allocator.dupe(u8, entry.path) catch @panic("OOM");

            const tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(path),
                    .target = native_target,
                    .optimize = optimize,
                }),
            });

            const run_tests = b.addRunArtifact(tests);
            run_tests.step.dependOn(check_step);
            test_step.dependOn(&run_tests.step);
            continue;
        }

        if (std.mem.endsWith(u8, entry.path, ".roc")) {
            const path = b.allocator.dupe(u8, entry.path) catch @panic("OOM");

            const check_format = b.addSystemCommand(&.{
                "roc",
                "fmt",
                "--check",
                path,
            });
            check_step.dependOn(&check_format.step);

            const write_format = b.addSystemCommand(&.{
                "roc",
                "fmt",
                path,
            });
            fmt_step.dependOn(&write_format.step);

            if (isRocTestRoot(root, io, b.allocator, entry.path)) {
                const run_tests = b.addSystemCommand(&.{
                    "roc",
                    "test",
                    path,
                });

                run_tests.step.dependOn(check_step);
                test_step.dependOn(&run_tests.step);
            }
        }
    }
}

fn isIgnoredTestDirectory(name: []const u8) bool {
    const ignored = [_][]const u8{
        ".direnv",
        ".git",
        ".zig-cache",
        "dist",
        "node_modules",
        "result",
        "zig-out",
    };

    for (ignored) |ignored_name| {
        if (std.mem.eql(u8, name, ignored_name)) return true;
    }

    return false;
}

fn isRocTestRoot(
    root: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) bool {
    const source = root.readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch return false;
    defer allocator.free(source);

    var lines = std.mem.splitScalar(
        u8,
        source,
        '\n',
    );

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(
            u8,
            line,
            " \t\r",
        );

        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            continue;
        }

        return std.mem.startsWith(u8, trimmed, "app [") or
            std.mem.startsWith(u8, trimmed, "platform \"") or
            std.mem.eql(u8, trimmed, "package");
    }

    return false;
}
