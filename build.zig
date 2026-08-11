const std = @import("std");

const SourceTree = struct {
    nix_files: []const []const u8,
    roc_apps: []const []const u8,
    roc_files: []const []const u8,
    roc_roots: []const []const u8,
    shell_files: []const []const u8,
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
    var shell_files = std.ArrayList([]const u8).empty;
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
        } else if (std.mem.endsWith(u8, path, ".sh")) {
            shell_files.append(allocator, path) catch @panic("out of memory");
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
    sortPaths(shell_files.items);
    sortPaths(zig_files.items);

    return .{
        .nix_files = nix_files.toOwnedSlice(allocator) catch @panic("out of memory"),
        .roc_apps = roc_apps.toOwnedSlice(allocator) catch @panic("out of memory"),
        .roc_files = roc_files.toOwnedSlice(allocator) catch @panic("out of memory"),
        .roc_roots = roc_roots.toOwnedSlice(allocator) catch @panic("out of memory"),
        .shell_files = shell_files.toOwnedSlice(allocator) catch @panic("out of memory"),
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

    const build_devtool = b.addSystemCommand(&.{ "roc", "build" });
    build_devtool.addFileArg(b.path("devtool/main.roc"));
    build_devtool.addFileInput(b.path("devtool/Cli.roc"));
    build_devtool.addFileInput(b.path("devtool/PrepareRelease.roc"));
    build_devtool.addFileInput(b.path("devtool/Release.roc"));
    build_devtool.addArg("--opt=dev");
    const devtool = build_devtool.addPrefixedOutputFileArg("--output=", "kai-devtool");
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
    const publish_release = addDevtoolCommand(b, devtool, "publish-release", forwarded_args);
    publish_release_step.dependOn(&publish_release.step);

    // All static checks (roc, zig, sh)
    const check_step = b.step(
        "check",
        "Run formatting and static checks",
    );
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

    const sh_fmt = addFilesCommand(
        b,
        &.{ "shfmt", "-d" },
        sources.shell_files,
        &.{},
    );
    check_step.dependOn(&sh_fmt.step);

    const check_scripts = addFilesCommand(
        b,
        &.{"shellcheck"},
        sources.shell_files,
        &.{},
    );
    check_step.dependOn(&check_scripts.step);

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
        const check_roc = b.addSystemCommand(&.{ "roc", "check", root });
        check_step.dependOn(&check_roc.step);
    }

    // Mutating format step. Convenience for devs who don't have
    // editor config for roc, zig, nix, and sh all setup.
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

    const sh_fmt_write = addFilesCommand(
        b,
        &.{ "shfmt", "-w" },
        sources.shell_files,
        &.{},
    );
    fmt_step.dependOn(&sh_fmt_write.step);

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
        const test_app = b.addSystemCommand(&.{ "roc", "test", app });
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
        const build_app = b.addSystemCommand(&.{
            "roc",
            "build",
            app,
            "--opt=dev",
            output,
        });
        build_app.step.dependOn(&prepare_outputs.step);
        ci_step.dependOn(&build_app.step);

        if (std.mem.eql(u8, app, "xkai-bin/main.roc")) {
            const test_portability = b.addSystemCommand(&.{
                "scripts/test-xkai-portability.sh",
                output_path,
            });
            test_portability.step.dependOn(&build_app.step);
            ci_step.dependOn(&test_portability.step);

            const test_projects = b.addSystemCommand(&.{
                "scripts/test-xkai-projects.sh",
                output_path,
            });
            test_projects.step.dependOn(&build_app.step);
            ci_step.dependOn(&test_projects.step);
        }
    }
}
