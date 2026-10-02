const std = @import("std");

const SourceTree = struct {
    fuzz_apps: []const []const u8,
    nix_files: []const []const u8,
    roc_apps: []const []const u8,
    roc_files: []const []const u8,
    roc_roots: []const []const u8,
    zig_files: []const []const u8,
};

const roc_build = [_][]const u8{ "roc", "build" };

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

    var fuzz_apps = std.ArrayList([]const u8).empty;
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
                const copy = allocator.dupe(u8, path) catch @panic("out of memory");
                // Fuzz targets only build instrumented; `zig build fuzz` owns
                // them, so ci neither checks nor builds them.
                if (std.mem.indexOf(u8, path, "/fuzz/") != null) {
                    fuzz_apps.append(allocator, copy) catch @panic("out of memory");
                    continue;
                }
                roc_roots.append(allocator, copy) catch @panic("out of memory");
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

    sortPaths(fuzz_apps.items);
    sortPaths(nix_files.items);
    sortPaths(roc_apps.items);
    sortPaths(roc_files.items);
    sortPaths(roc_roots.items);
    sortPaths(zig_files.items);

    return .{
        .fuzz_apps = fuzz_apps.toOwnedSlice(allocator) catch @panic("out of memory"),
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

// One end-to-end test, or `all`, with fixed flags, then any flags passed
// after `--`, then the Nix-installed and bare kai.
fn addE2e(
    b: *std.Build,
    devtool: std.Build.LazyPath,
    test_name: []const u8,
    kai: std.Build.LazyPath,
    bare: std.Build.LazyPath,
    flags: []const []const u8,
) *std.Build.Step.Run {
    const run = addDevtoolCommand(b, devtool, "e2e", &.{test_name});
    run.setName(b.fmt("run devtool e2e {s}", .{test_name}));
    run.addArgs(flags);
    if (b.args) |args| run.addArgs(args);
    run.addFileArg(kai);
    run.addFileArg(bare);
    return run;
}

fn addNixOutLink(
    b: *std.Build,
    prerequisite: *std.Build.Step,
    installable: []const u8,
    name: []const u8,
) std.Build.LazyPath {
    const build_package = b.addSystemCommand(&.{ "nix", "build", installable, "--out-link" });
    const out_link = build_package.addOutputFileArg(name);
    build_package.has_side_effects = true;
    build_package.step.dependOn(prerequisite);
    return out_link;
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
    build_devtool.addFileInput(b.path("devtool/Fuzz.roc"));
    for ([_][]const u8{
        "Bundles",     "E2e",        "E2eBuild", "E2eBundle", "E2eHelp",
        "E2eOverlays", "E2ePlugins", "E2eRun",   "E2eUpdate", "E2eWorkflow",
    }) |module| {
        build_devtool.addFileInput(b.path(b.fmt("devtool/{s}.roc", .{module})));
    }
    for (sources.roc_files) |source| {
        if (std.mem.startsWith(u8, source, "platform/") or
            std.mem.startsWith(u8, source, "plugins/std/model/") or
            std.mem.startsWith(u8, source, "plugins/std/backends/"))
        {
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

    // Opt-in, for before a release or after touching a parser; not in ci.
    const fuzz_seconds = b.option(
        u32,
        "fuzz-seconds",
        "Seconds `zig build fuzz` runs each target (default 30)",
    ) orelse 30;
    const fuzz_step = b.step(
        "fuzz",
        "Build and run each roc-fuzz target; inputs land in zig-out/fuzz",
    );
    const run_fuzz = addDevtoolCommand(b, devtool, "fuzz", &.{
        b.fmt("{d}", .{fuzz_seconds}),
    });
    run_fuzz.addArgs(sources.fuzz_apps);
    fuzz_step.dependOn(&run_fuzz.step);

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
        "Build the Kai platform bundle a release publishes, into zig-out",
    );
    const platform_bundle = b.addSystemCommand(&.{
        "nix", "build", ".#kai-platform", "--out-link", "zig-out/kai-platform",
    });
    platform_bundle_step.dependOn(&platform_bundle.step);

    // Configuration apps link the native configuration platform's host.
    const build_platform_host = b.addSystemCommand(&.{ "zig", "build", "--release" });
    build_platform_host.setCwd(b.path("platform"));

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

    const test_platform = b.addSystemCommand(&.{
        "roc",
        "test",
        "platform/main.roc",
    });
    test_platform.step.dependOn(check_step);
    test_step.dependOn(&test_platform.step);

    const test_std_model = b.addSystemCommand(&.{
        "roc",
        "test",
        "plugins/std/model/main.roc",
    });
    test_std_model.step.dependOn(check_step);
    test_step.dependOn(&test_std_model.step);

    const test_std_nix = b.addSystemCommand(&.{
        "roc",
        "test",
        "plugins/std/backends/nix/main.roc",
    });
    test_std_nix.step.dependOn(check_step);
    test_step.dependOn(&test_std_nix.step);

    const test_std_guix = b.addSystemCommand(&.{
        "roc",
        "test",
        "plugins/std/backends/guix/main.roc",
    });
    test_std_guix.step.dependOn(check_step);
    test_step.dependOn(&test_std_guix.step);

    // plugins/std has no test root yet: `roc test` panics when the platform
    // and a package it depends on share a module name (model, nix and guix
    // reach the platform's modules again through api.roc, so Sexpr appears
    // twice; roc-issues-repro BUG-012, not yet reported upstream). Add
    // `roc test plugins/std/main.roc` with a Roc release that fixes it.

    const test_cli = b.addSystemCommand(&.{ "roc", "test", "cli/main.roc" });
    test_cli.step.dependOn(check_step);
    test_step.dependOn(&test_cli.step);

    const ci_step = b.step(
        "ci",
        "Run tests and build representative applications",
    );
    ci_step.dependOn(test_step);

    // Integration steps run the kai that ships, not a --opt=dev build: the
    // Nix package's wrapper, and the bare binary a release archive holds for
    // steps that must not see the wrapper's Nix or seeded Roc cache. Nix
    // decides what to rebuild, so these always run; new files need `git add`.
    const cli_binary = addNixOutLink(b, test_step, ".#kai", "kai").path(b, "bin/kai");
    const bare_binary = addNixOutLink(
        b,
        test_step,
        ".#kai.unwrapped",
        "kai-unwrapped",
    ).path(b, "bin/kai");
    // Every maintained example must load and lower to std's model.
    const examples = [_][]const u8{
        "examples/artifacts",
        "examples/composition",
        "examples/guix",
        "examples/overlays",
    };
    for (examples) |example| {
        for ([_][]const u8{ "check", "model" }) |command| {
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

    // Resolves nixpkgs with real Nix, so it needs network or a warm cache.
    // End-to-end tests run a built kai on example projects against real
    // backends: Nix halves with the Nix-installed kai, Guix halves with the
    // bare kai and only guix and coreutils on PATH, skipped without guix.
    // `zig build e2e` runs them all and `zig build e2e-<test>` one; pass
    // `-- --nix` or `-- --guix` to run one backend.
    const e2e_tests = [_][]const u8{
        "run", "build", "workflow", "update", "overlays", "help", "plugins", "bundle",
    };
    const e2e_step = b.step("e2e", "Run every end-to-end test (-- --nix | --guix)");
    const run_e2e = addE2e(b, devtool, "all", cli_binary, bare_binary, &.{});
    e2e_step.dependOn(&run_e2e.step);
    ci_step.dependOn(e2e_step);
    for (e2e_tests) |test_name| {
        const step = b.step(
            b.fmt("e2e-{s}", .{test_name}),
            b.fmt("Run the {s} end-to-end test (-- --nix | --guix)", .{test_name}),
        );
        step.dependOn(&addE2e(b, devtool, test_name, cli_binary, bare_binary, &.{}).step);
    }

    const smoke_step = b.step(
        "smoke",
        "Run the update and run end-to-end tests on Nix, the cheap real checks",
    );
    for ([_][]const u8{ "update", "run" }) |test_name| {
        const smoke = addE2e(b, devtool, test_name, cli_binary, bare_binary, &.{"--nix"});
        smoke_step.dependOn(&smoke.step);
    }

    // The hosted Guix CI gate: every Guix half, failing without guix.
    const guix_integration_step = b.step(
        "guix-integration",
        "Run every end-to-end test on real Guix without Nix; fails without guix",
    );
    const run_guix_integration = addE2e(
        b,
        devtool,
        "all",
        cli_binary,
        bare_binary,
        &.{ "--guix", "--require-guix" },
    );
    guix_integration_step.dependOn(&run_guix_integration.step);

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

    _ = addCiCommand(
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
    );

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
