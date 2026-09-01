const std = @import("std");

const SourceTree = struct {
    nix_files: []const []const u8,
    roc_apps: []const []const u8,
    roc_files: []const []const u8,
    roc_roots: []const []const u8,
    xkai_files: []const []const u8,
    zig_files: []const []const u8,
};

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
    "fuzz",
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

fn discoverRegularFiles(
    b: *std.Build,
    root: []const u8,
) []const []const u8 {
    const allocator = b.allocator;
    const io = b.graph.io;
    const root_path = b.fmt(
        "{s}/{s}",
        .{ b.build_root.path orelse ".", root },
    );
    var root_dir = std.Io.Dir.cwd().openDir(
        io,
        root_path,
        .{ .iterate = true, .follow_symlinks = false },
    ) catch @panic("failed to open embedded source root");
    defer root_dir.close(io);

    var files = std.ArrayList([]const u8).empty;
    var walker = root_dir.walk(allocator) catch
        @panic("failed to scan embedded source root");
    defer walker.deinit();
    while (walker.next(io) catch
        @panic("failed to scan embedded source root")) |entry|
    {
        if (entry.kind != .file) continue;
        if (std.fs.path.isAbsolute(entry.path)) {
            @panic("embedded source escaped its root");
        }
        const path = b.fmt("{s}/{s}", .{ root, entry.path });
        files.append(allocator, path) catch @panic("out of memory");
    }
    sortPaths(files.items);
    return files.toOwnedSlice(allocator) catch @panic("out of memory");
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
        } else if (std.mem.endsWith(u8, path, ".nix")) {
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
        .xkai_files = discoverRegularFiles(b, "xkai"),
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

    const source_stage = b.addWriteFiles();
    _ = source_stage.addCopyDirectory(b.path("xkai"), "xkai", .{});
    _ = source_stage.addCopyDirectory(
        b.path("plugins/std"),
        "plugins/std",
        .{},
    );

    const bundle = b.addSystemCommand(&.{ "roc", "bundle", "--output-dir" });
    const bundle_dir = bundle.addOutputDirectoryArg("xkai-bundle");
    for (sources.xkai_files) |source| {
        bundle.addArg(source);
        bundle.addFileInput(b.path(source));
    }

    const build_devtool = b.addSystemCommand(&.{ "roc", "build" });
    build_devtool.addFileArg(b.path("devtool/main.roc"));
    build_devtool.addFileInput(b.path("devtool/Cli.roc"));
    build_devtool.addFileInput(b.path("devtool/Kaifiles.roc"));
    build_devtool.addFileInput(b.path("devtool/GitHub.roc"));
    build_devtool.addFileInput(b.path("devtool/PrepareRelease.roc"));
    build_devtool.addFileInput(b.path("devtool/PrepareXkai.roc"));
    build_devtool.addFileInput(b.path("devtool/Release.roc"));
    build_devtool.addFileInput(b.path("devtool/Tidy.roc"));
    build_devtool.addArg("--opt=dev");
    const devtool = build_devtool.addPrefixedOutputFileArg("--output=", "kai-devtool");

    const prepare = std.Build.Step.Run.create(b, "run devtool prepare-xkai");
    prepare.addFileArg(devtool);
    prepare.addArg("prepare-xkai");
    prepare.addDirectoryArg(bundle_dir);
    prepare.addDirectoryArg(source_stage.getDirectory());
    const generated_tree = prepare.addOutputDirectoryArg("generated-xkai");
    const generated_main = generated_tree.path(b, "xkai/main.roc");
    const install_generated_tree = b.addInstallDirectory(.{
        .source_dir = generated_tree,
        .install_dir = .prefix,
        .install_subdir = "xkai-source",
    });

    const prepare_step = b.step(
        "prepare-xkai",
        "Generate the xkai source tree and embedded archive",
    );
    prepare_step.dependOn(&install_generated_tree.step);

    const build_publish_devtool = b.addSystemCommand(&.{ "roc", "build" });
    build_publish_devtool.addFileArg(b.path("devtool/publish.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/GitHub.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/GitHubApi.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/PublishRelease.roc"));
    build_publish_devtool.addFileInput(b.path("devtool/Release.roc"));
    build_publish_devtool.addArg("--opt=dev");
    const publish_devtool = build_publish_devtool.addPrefixedOutputFileArg("--output=", "kai-publish-devtool");
    const forwarded_args = b.args orelse &.{};

    const build_examples_devtool = b.addSystemCommand(&.{ "roc", "build" });
    build_examples_devtool.addFileArg(b.path("devtool/test-examples.roc"));
    build_examples_devtool.addFileInput(b.path("devtool/Examples.roc"));
    for (sources.roc_files) |source| {
        if (std.mem.startsWith(u8, source, "plugins/") or
            std.mem.startsWith(u8, source, "xkai/"))
        {
            build_examples_devtool.addFileInput(b.path(source));
        }
    }
    build_examples_devtool.addArg("--opt=dev");
    const examples_devtool = build_examples_devtool.addPrefixedOutputFileArg(
        "--output=",
        "kai-test-examples",
    );

    const test_examples_step = b.step(
        "test-examples",
        "Recursively test every Kaifile example",
    );
    const test_examples = std.Build.Step.Run.create(b, "run Kaifile examples test");
    test_examples.addFileArg(examples_devtool);
    test_examples.addArg("examples/kaifiles");
    test_examples_step.dependOn(&test_examples.step);

    const kaifiles_step = b.step(
        "kaifiles",
        "Run every Kaifile and compare its generated outputs",
    );
    const run_kaifiles = addDevtoolCommand(b, devtool, "kaifiles", &.{});
    kaifiles_step.dependOn(&run_kaifiles.step);

    const build_fuzz = b.addSystemCommand(&.{ "roc", "build", "--fuzz" });
    build_fuzz.addFileArg(b.path("fuzz/Config.roc"));
    build_fuzz.addFileInput(b.path("xkai/parser/main.roc"));
    build_fuzz.addFileInput(b.path("xkai/parser/Blocks.roc"));
    const fuzz_executable = build_fuzz.addPrefixedOutputFileArg(
        "--output=",
        "kai-config-fuzz",
    );

    const fuzz_step = b.step("fuzz", "Build and run the Config fuzz target");
    const run_fuzz = std.Build.Step.Run.create(b, "run Config fuzz campaign");
    run_fuzz.addFileArg(fuzz_executable);
    run_fuzz.addArg("run");
    fuzz_step.dependOn(&run_fuzz.step);

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

    for (sources.roc_roots) |root| {
        const check_roc = b.addSystemCommand(&.{ "roc", "check" });
        if (std.mem.eql(u8, root, "xkai/main.roc")) {
            check_roc.addFileArg(generated_main);
        } else {
            check_roc.addArg(root);
        }
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

    for (sources.roc_apps) |app| {
        const test_app = b.addSystemCommand(&.{ "roc", "test" });
        if (std.mem.eql(u8, app, "xkai/main.roc")) {
            test_app.addFileArg(generated_main);
        } else {
            test_app.addArg(app);
        }
        test_app.step.dependOn(check_step);
        test_step.dependOn(&test_app.step);
    }

    const ci_step = b.step(
        "ci",
        "Run tests and build representative applications",
    );
    ci_step.dependOn(test_step);
    build_release.step.dependOn(ci_step);

    const nix_flake_check = addCiCommand(
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
            &nix_flake_check.step,
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
            &nix_flake_check.step,
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
        const build_app = b.addSystemCommand(&.{ "roc", "build" });
        if (std.mem.eql(u8, app, "xkai/main.roc")) {
            build_app.addFileArg(generated_main);
        } else {
            build_app.addArg(app);
        }
        build_app.addArgs(&.{ "--opt=dev", output });
        build_app.step.dependOn(&prepare_outputs.step);
        ci_step.dependOn(&build_app.step);
    }
}
