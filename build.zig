const std = @import("std");

const SourceTree = struct {
    nix_files: []const []const u8,
    roc_apps: []const []const u8,
    roc_files: []const []const u8,
    roc_roots: []const []const u8,
    zig_files: []const []const u8,
};

// Cached `roc build` object packs can be reused by another app and segfault the
// compiler (https://github.com/roc-lang/roc/issues/11673). Drop --no-cache
// once the Roc pin includes https://github.com/roc-lang/roc/pull/11676.
const roc_build = [_][]const u8{ "roc", "build", "--no-cache" };

const RocRootKind = enum {
    app,
    package,
};

const excluded_source_dirs = [_][]const u8{
    ".direnv",
    ".git",
    ".kai",
    ".zig-cache",
    "dist",
    "zig-out",
};

fn isExcludedSourceDir(name: []const u8) bool {
    for (excluded_source_dirs) |excluded| {
        if (std.mem.eql(u8, name, excluded)) return true;
    }
    return false;
}

fn rocRootKind(contents: []const u8) ?RocRootKind {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "app ")) return .app;
        if (std.mem.startsWith(u8, line, "package")) return .package;
        return null;
    }
    return null;
}

fn sortPaths(paths: [][]const u8) void {
    std.mem.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
}

fn discoverSources(b: *std.Build) SourceTree {
    const allocator = b.allocator;
    const io = b.graph.io;

    var nix_files = std.ArrayList([]const u8).empty;
    var roc_apps = std.ArrayList([]const u8).empty;
    var roc_files = std.ArrayList([]const u8).empty;
    var roc_roots = std.ArrayList([]const u8).empty;
    var zig_files = std.ArrayList([]const u8).empty;

    var source_dir = std.Io.Dir.cwd().openDir(
        io,
        b.build_root.path orelse ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) catch @panic("failed to open source tree");
    defer source_dir.close(io);

    var walker = source_dir.walk(allocator) catch @panic("failed to scan source tree");
    defer walker.deinit();

    while (walker.next(io) catch @panic("failed to scan source tree")) |entry| {
        if (entry.kind == .directory and isExcludedSourceDir(entry.basename)) {
            walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;

        const path = allocator.dupe(u8, entry.path) catch @panic("out of memory");
        if (std.mem.endsWith(u8, path, ".roc")) {
            roc_files.append(allocator, path) catch @panic("out of memory");

            const contents = source_dir.readFileAlloc(
                io,
                path,
                allocator,
                .limited(10 * 1024 * 1024),
            ) catch @panic("failed to read Roc source");
            defer allocator.free(contents);

            if (rocRootKind(contents)) |kind| {
                roc_roots.append(allocator, allocator.dupe(u8, path) catch @panic("out of memory")) catch @panic("out of memory");
                if (kind == .app) {
                    roc_apps.append(allocator, allocator.dupe(u8, path) catch @panic("out of memory")) catch @panic("out of memory");
                }
            }
        } else if (std.mem.endsWith(u8, path, ".zig")) {
            zig_files.append(allocator, path) catch @panic("out of memory");
        } else if (std.mem.endsWith(u8, path, ".nix") and
            // Golden files are exact renderer output, not formatted sources.
            !std.mem.endsWith(u8, path, ".golden.nix"))
        {
            nix_files.append(allocator, path) catch @panic("out of memory");
        } else {
            allocator.free(path);
        }
    }

    sortPaths(nix_files.items);
    sortPaths(roc_apps.items);
    sortPaths(roc_files.items);
    sortPaths(roc_roots.items);
    sortPaths(zig_files.items);

    return .{
        .nix_files = nix_files.toOwnedSlice(allocator) catch @panic("out of memory"),
        .roc_apps = roc_apps.toOwnedSlice(allocator) catch @panic("out of memory"),
        .roc_files = roc_files.toOwnedSlice(allocator) catch @panic("out of memory"),
        .roc_roots = roc_roots.toOwnedSlice(allocator) catch @panic("out of memory"),
        .zig_files = zig_files.toOwnedSlice(allocator) catch @panic("out of memory"),
    };
}

fn addFilesCommand(
    b: *std.Build,
    prefix: []const []const u8,
    files: []const []const u8,
    suffix: []const []const u8,
) *std.Build.Step.Run {
    var args = std.ArrayList([]const u8).empty;
    args.appendSlice(b.allocator, prefix) catch @panic("out of memory");
    args.appendSlice(b.allocator, files) catch @panic("out of memory");
    args.appendSlice(b.allocator, suffix) catch @panic("out of memory");
    return b.addSystemCommand(args.items);
}

fn addCiCommand(
    b: *std.Build,
    ci_step: *std.Build.Step,
    prerequisite: *std.Build.Step,
    name: []const u8,
    args: []const []const u8,
) *std.Build.Step.Run {
    const command = std.Build.Step.Run.create(b, name);
    command.addArgs(args);
    command.step.dependOn(prerequisite);
    ci_step.dependOn(&command.step);
    return command;
}

fn addDevtoolCommand(
    b: *std.Build,
    devtool: std.Build.LazyPath,
    command: []const u8,
    forwarded_args: []const []const u8,
) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("run devtool {s}", .{command}));
    run.addFileArg(devtool);
    run.addArg(command);
    run.addArgs(forwarded_args);
    return run;
}

fn artifactName(b: *std.Build, source_path: []const u8) []const u8 {
    const extension_len = ".roc".len;
    const stem = source_path[0 .. source_path.len - extension_len];
    const name = b.allocator.alloc(u8, stem.len) catch @panic("out of memory");
    for (stem, name) |char, *output| {
        output.* = if (std.ascii.isAlphanumeric(char)) char else '-';
    }
    return name;
}

pub fn build(b: *std.Build) void {
    const sources = discoverSources(b);

    const build_devtool = b.addSystemCommand(&roc_build);
    build_devtool.addFileArg(b.path("devtool/main.roc"));
    build_devtool.addFileInput(b.path("devtool/Cli.roc"));
    build_devtool.addFileInput(b.path("devtool/ConfigFixtures.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiBuild.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiBundle.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiEnv.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiGuix.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiHelp.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiRun.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiUpdate.roc"));
    build_devtool.addFileInput(b.path("devtool/KaiWorkflow.roc"));
    for (sources.roc_files) |source| {
        if (std.mem.startsWith(u8, source, "kaifile/")) {
            build_devtool.addFileInput(b.path(source));
        }
    }
    build_devtool.addFileInput(b.path("devtool/GitHub.roc"));
    build_devtool.addFileInput(b.path("devtool/PrepareRelease.roc"));
    build_devtool.addFileInput(b.path("devtool/Release.roc"));
    build_devtool.addFileInput(b.path("devtool/Tidy.roc"));
    build_devtool.addArg("--opt=dev");
    const devtool = build_devtool.addPrefixedOutputFileArg("--output=", "kai-devtool");

    const build_publish_devtool = b.addSystemCommand(&roc_build);
    build_publish_devtool.addFileArg(b.path("devtool/publish.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/GitHub.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/GitHubApi.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/PublishRelease.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/Release.roc"));
    build_publish_devtool.addArg("--opt=dev");
    const publish_devtool = build_publish_devtool.addPrefixedOutputFileArg("--output=", "kai-publish-devtool");
    const forwarded_args = b.args orelse &.{};

    const build_release_step = b.step(
        "build-release",
        "Build and validate release artifacts",
    );
    const build_release = addDevtoolCommand(b, devtool, "build-release", forwarded_args);
    build_release_step.dependOn(&build_release.step);

    const release_step = b.step(
        "release",
        "Prepare and push a protected-branch release",
    );
    const prepare_release = addDevtoolCommand(b, devtool, "prepare-release", forwarded_args);
    release_step.dependOn(&prepare_release.step);

    const publish_release_step = b.step(
        "publish-release",
        "Publish a merged release (CI only)",
    );
    const publish_release = std.Build.Step.Run.create(b, "run publish devtool");
    publish_release.addFileArg(publish_devtool);
    publish_release.addArgs(forwarded_args);
    publish_release_step.dependOn(&publish_release.step);

    // All static checks (Roc and Zig).
    const tidy_step = b.step(
        "tidy",
        "Check Roc source invariants",
    );
    const tidy_check = addDevtoolCommand(b, devtool, "tidy", &.{});
    tidy_step.dependOn(&tidy_check.step);

    const check_step = b.step(
        "check",
        "Run formatting and static checks",
    );
    check_step.dependOn(tidy_step);
    const roc_fmt = addFilesCommand(
        b,
        &.{ "roc", "fmt", "--check" },
        sources.roc_files,
        &.{},
    );
    check_step.dependOn(&roc_fmt.step);

    const zig_fmt = addFilesCommand(
        b,
        &.{ "zig", "fmt", "--check" },
        sources.zig_files,
        &.{},
    );
    check_step.dependOn(&zig_fmt.step);

    const check_actions = b.addSystemCommand(&.{"actionlint"});
    check_step.dependOn(&check_actions.step);

    const nix_fmt = addFilesCommand(
        b,
        &.{ "nix", "fmt" },
        sources.nix_files,
        &.{ "--", "--check" },
    );
    check_step.dependOn(&nix_fmt.step);

    const platform_bundle_step = b.step(
        "platform-bundle",
        "Build the Kaifile platform bundle a release publishes, into zig-out",
    );
    const platform_bundle = b.addSystemCommand(&.{
        "nix", "build", ".#kaifile-platform", "--out-link", "zig-out/kaifile-platform",
    });
    platform_bundle_step.dependOn(&platform_bundle.step);

    // Configuration apps link the native configuration platform's host.
    const build_platform_host = b.addSystemCommand(&.{ "zig", "build", "--release" });
    build_platform_host.setCwd(b.path("kaifile/platform"));

    for (sources.roc_roots) |root| {
        const check_roc = b.addSystemCommand(&.{ "roc", "check" });
        check_roc.step.dependOn(&build_platform_host.step);
        check_roc.addArg(root);
        check_step.dependOn(&check_roc.step);
    }

    // Mutating format step. Convenience for devs who don't have
    // editor config for Roc, Zig, and Nix all setup.
    //
    // Not used in CI -- CI only does static checks.
    const fmt_step = b.step("fmt", "Format all source code files.");

    const roc_fmt_write = addFilesCommand(
        b,
        &.{ "roc", "fmt" },
        sources.roc_files,
        &.{},
    );
    fmt_step.dependOn(&roc_fmt_write.step);

    const zig_fmt_write = addFilesCommand(
        b,
        &.{ "zig", "fmt" },
        sources.zig_files,
        &.{},
    );
    fmt_step.dependOn(&zig_fmt_write.step);

    const nix_fmt_write = addFilesCommand(
        b,
        &.{ "nix", "fmt" },
        sources.nix_files,
        &.{},
    );
    fmt_step.dependOn(&nix_fmt_write.step);

    const test_step = b.step(
        "test",
        "Run checks and Roc tests.",
    );
    test_step.dependOn(check_step);

    const test_kaifile_ir = b.addSystemCommand(&.{
        "roc",
        "test",
        "kaifile/ir/main.roc",
    });
    test_kaifile_ir.step.dependOn(check_step);
    test_step.dependOn(&test_kaifile_ir.step);

    const test_kaifile_nix = b.addSystemCommand(&.{
        "roc",
        "test",
        "kaifile/nix/main.roc",
    });
    test_kaifile_nix.step.dependOn(check_step);
    test_step.dependOn(&test_kaifile_nix.step);

    const test_kaifile_guix = b.addSystemCommand(&.{
        "roc",
        "test",
        "kaifile/guix/main.roc",
    });
    test_kaifile_guix.step.dependOn(check_step);
    test_step.dependOn(&test_kaifile_guix.step);

    const test_cli = b.addSystemCommand(&.{ "roc", "test", "cli/main.roc" });
    test_cli.step.dependOn(check_step);
    test_step.dependOn(&test_cli.step);

    const ci_step = b.step(
        "ci",
        "Run tests and build representative applications",
    );
    ci_step.dependOn(test_step);

    // Load a real Kaifile.roc through the compiled CLI.
    const build_cli = b.addSystemCommand(&roc_build);
    build_cli.addArgs(&.{ "cli/main.roc", "--opt=dev" });
    const cli_binary = build_cli.addPrefixedOutputFileArg("--output=", "kai");
    for (sources.roc_files) |source| {
        if (std.mem.startsWith(u8, source, "cli/") or
            std.mem.startsWith(u8, source, "kaifile/"))
        {
            build_cli.addFileInput(b.path(source));
        }
    }
    build_cli.addFileInput(b.path("kaifile/platform-release"));
    build_cli.step.dependOn(test_step);
    // Every maintained example must load and lower to IR.
    const examples = [_][]const u8{
        "examples/artifacts",
        "examples/composition",
        "examples/guix",
        "examples/overlays",
    };
    for (examples) |example| {
        for ([_][]const u8{ "check", "ir" }) |command| {
            const smoke = std.Build.Step.Run.create(
                b,
                b.fmt("kai {s} {s}", .{ command, example }),
            );
            smoke.addFileArg(cli_binary);
            smoke.addArg(command);
            smoke.setCwd(b.path(example));
            smoke.expectExitCode(0);
            ci_step.dependOn(&smoke.step);
        }
    }
    const check_root = std.Build.Step.Run.create(b, "kai check Kaifile.roc");
    check_root.addFileArg(cli_binary);
    check_root.addArg("check");
    check_root.setCwd(b.path("."));
    check_root.expectExitCode(0);
    ci_step.dependOn(&check_root.step);

    // Resolves nixpkgs with real Nix, so it needs network or a warm cache.
    const kai_update_step = b.step(
        "kai-update",
        "Run kai update with real Nix on a copy of examples/composition",
    );
    const run_kai_update = addDevtoolCommand(b, devtool, "kai-update", &.{});
    run_kai_update.addFileArg(cli_binary);
    kai_update_step.dependOn(&run_kai_update.step);
    ci_step.dependOn(kai_update_step);

    const kai_run_step = b.step(
        "kai-run",
        "Run kai run and kai shell with real Nix on examples/composition",
    );
    const run_kai_run = addDevtoolCommand(b, devtool, "kai-run", &.{});
    run_kai_run.addFileArg(cli_binary);
    kai_run_step.dependOn(&run_kai_run.step);
    ci_step.dependOn(kai_run_step);

    const kai_env_step = b.step(
        "kai-env",
        "Run kai shell and kai run with real Nix on examples/overlays",
    );
    const run_kai_env = addDevtoolCommand(b, devtool, "kai-env", &.{});
    run_kai_env.addFileArg(cli_binary);
    kai_env_step.dependOn(&run_kai_env.step);
    ci_step.dependOn(kai_env_step);

    // Stubbed Guix checks always run; the real Guix shell is reported as
    // SKIPPED without guix. guix-integration requires it (hosted CI gate).
    const kai_guix_step = b.step(
        "kai-guix",
        "Run kai shell against stub and, if installed, real Guix",
    );
    const run_kai_guix = addDevtoolCommand(b, devtool, "kai-guix", &.{});
    run_kai_guix.addFileArg(cli_binary);
    kai_guix_step.dependOn(&run_kai_guix.step);
    ci_step.dependOn(kai_guix_step);

    const guix_integration_step = b.step(
        "guix-integration",
        "Run kai shell against real Guix without Nix; fails without guix",
    );
    const run_guix_integration = addDevtoolCommand(
        b,
        devtool,
        "kai-guix",
        &.{"--require"},
    );
    run_guix_integration.addFileArg(cli_binary);
    guix_integration_step.dependOn(&run_guix_integration.step);

    // Real sandboxed builds; the sandbox probe needs a world-readable /var/tmp.
    const kai_build_step = b.step(
        "kai-build",
        "Run kai build with real, sandboxed Nix on examples/artifacts",
    );
    const run_kai_build = addDevtoolCommand(b, devtool, "kai-build", &.{});
    run_kai_build.addFileArg(cli_binary);
    kai_build_step.dependOn(&run_kai_build.step);
    ci_step.dependOn(kai_build_step);

    // Real workflows and JSON output, on examples/artifacts like kai-build.
    const kai_workflow_step = b.step(
        "kai-workflow",
        "Run kai workflow and kai --json with real Nix on examples/artifacts",
    );
    const run_kai_workflow = addDevtoolCommand(b, devtool, "kai-workflow", &.{});
    run_kai_workflow.addFileArg(cli_binary);
    kai_workflow_step.dependOn(&run_kai_workflow.step);
    ci_step.dependOn(kai_workflow_step);

    const kai_bundle_step = b.step(
        "kai-bundle",
        "Load a Kaifile.roc through the served and the pre-seeded platform bundle",
    );
    const run_kai_bundle = addDevtoolCommand(b, devtool, "kai-bundle", &.{});
    run_kai_bundle.addFileArg(cli_binary);
    kai_bundle_step.dependOn(&run_kai_bundle.step);
    ci_step.dependOn(kai_bundle_step);

    const kai_help_step = b.step(
        "kai-help",
        "Compile and run the examples in kai help with real Nix",
    );
    const run_kai_help = addDevtoolCommand(b, devtool, "kai-help", &.{});
    run_kai_help.addFileArg(cli_binary);
    kai_help_step.dependOn(&run_kai_help.step);
    ci_step.dependOn(kai_help_step);

    const config_fixtures_step = b.step(
        "config-fixtures",
        "Check Kaifile.roc configs are accepted or rejected at compile time",
    );
    const run_config_fixtures = addDevtoolCommand(
        b,
        devtool,
        "config-fixtures",
        &.{},
    );
    run_config_fixtures.step.dependOn(&build_platform_host.step);
    config_fixtures_step.dependOn(&run_config_fixtures.step);
    ci_step.dependOn(config_fixtures_step);
    build_release.step.dependOn(ci_step);

    _ = addCiCommand(
        b,
        ci_step,
        test_step,
        "check Nix flake",
        &.{ "nix", "flake", "check" },
    );

    switch (b.graph.host.result.os.tag) {
        .linux => _ = addCiCommand(
            b,
            ci_step,
            test_step,
            "build Linux release outputs",
            &.{
                "nix",
                "build",
                ".#release-x86_64-linux",
                ".#release-aarch64-linux",
                "--no-link",
            },
        ),
        .macos => _ = addCiCommand(
            b,
            ci_step,
            test_step,
            "skip Linux release outputs on Darwin",
            &.{ "echo", "Skipping Linux-only release output builds on Darwin" },
        ),
        else => @panic("zig build ci supports only Linux and Darwin hosts"),
    }

    // Avoid shell redirection or mkdir inside a script.
    const prepare_outputs = b.addSystemCommand(&.{
        "mkdir", "-p", "zig-out/ci", "zig-out/tests",
    });
    prepare_outputs.step.dependOn(test_step);

    for (sources.roc_apps) |app| {
        const output_path = b.fmt(
            "zig-out/ci/{s}-{x}",
            .{ artifactName(b, app), std.hash.Wyhash.hash(0, app) },
        );
        const output = b.fmt("--output={s}", .{output_path});
        const build_app = b.addSystemCommand(&roc_build);
        build_app.addArg(app);
        build_app.addArgs(&.{ "--opt=dev", output });
        build_app.step.dependOn(&prepare_outputs.step);
        ci_step.dependOn(&build_app.step);
    }
}
