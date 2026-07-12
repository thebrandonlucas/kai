//! Backend-neutral Kai shell protocol execution.
//!
//! This module contains the generic host/CLI adapter protocol plumbing. Backend
//! lowering stays in Roc adapters; host-side process execution may still wrap
//! recognized backend subprocesses to preserve terminal UX.
const std = @import("std");
const builtin = @import("builtin");
const spinner_mod = @import("spinner.zig");

const adapter_request_protocol = "kai.adapter.argv.v1";
const adapter_plan_protocol = "kai.adapter.plan.v1";

pub fn executeProtocolCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    adapter: []const u8,
    command: []const u8,
    target: []const u8,
    command_args: []const []const u8,
) ![]u8 {
    const code = try executeProtocolCommandStatus(allocator, io, adapter, command, target, command_args);
    if (code == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "kai: subprocess exited with status {d}\n", .{code});
}

pub fn executeProtocolCommandStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    adapter: []const u8,
    command: []const u8,
    target: []const u8,
    command_args: []const []const u8,
) !u8 {
    const plan_argv = try adapterPlanArgv(allocator, io, adapter, command, target, command_args);
    defer freeAdapterPlan(allocator, plan_argv);

    return runShellArgvStatus(allocator, io, plan_argv);
}

fn adapterPlanArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    adapter: []const u8,
    command: []const u8,
    target: []const u8,
    command_args: []const []const u8,
) ![]const []const u8 {
    if (!std.mem.eql(u8, command, "shell")) {
        return error.UnsupportedProtocolCommand;
    }

    const adapter_argv = try buildAdapterArgv(allocator, adapter, command, target, command_args);
    defer allocator.free(adapter_argv);

    const plan_bytes = try runAdapter(allocator, io, adapter_argv);
    defer allocator.free(plan_bytes);

    const plan_argv = try parseAdapterPlan(allocator, plan_bytes);
    errdefer freeAdapterPlan(allocator, plan_argv);

    if (plan_argv.len == 0) {
        return error.EmptyExecutionPlan;
    }

    return plan_argv;
}

pub fn buildAdapterArgv(
    allocator: std.mem.Allocator,
    adapter: []const u8,
    command: []const u8,
    target: []const u8,
    command_args: []const []const u8,
) ![]const []const u8 {
    if (adapter.len == 0) {
        return error.MissingBackendAdapter;
    }

    const adapter_argv = try allocator.alloc([]const u8, 4 + command_args.len);
    adapter_argv[0] = adapter;
    adapter_argv[1] = adapter_request_protocol;
    adapter_argv[2] = command;
    adapter_argv[3] = target;
    for (command_args, 0..) |arg, index| {
        adapter_argv[4 + index] = arg;
    }
    return adapter_argv;
}

pub fn runAdapter(
    allocator: std.mem.Allocator,
    io: std.Io,
    adapter_argv: []const []const u8,
) ![]u8 {
    if (adapter_argv.len == 0 or adapter_argv[0].len == 0) {
        return error.MissingBackendAdapter;
    }

    const result = try std.process.run(allocator, io, .{
        .argv = adapter_argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                return allocator.dupe(u8, result.stdout);
            }
            return error.AdapterFailed;
        },
        .signal => return error.AdapterFailed,
        .stopped => return error.AdapterFailed,
        .unknown => return error.AdapterFailed,
    }
}

pub fn parseAdapterPlan(allocator: std.mem.Allocator, plan_bytes: []const u8) ![]const []const u8 {
    var cursor: usize = 0;

    const protocol = try readPlanLine(plan_bytes, &cursor);
    if (!std.mem.eql(u8, protocol, adapter_plan_protocol)) {
        return error.UnsupportedAdapterProtocol;
    }

    const count_line = try readPlanLine(plan_bytes, &cursor);
    const count = try std.fmt.parseInt(usize, count_line, 10);
    const argv = try allocator.alloc([]const u8, count);
    var initialized: usize = 0;
    errdefer {
        for (argv[0..initialized]) |arg| {
            allocator.free(arg);
        }
        allocator.free(argv);
    }

    while (initialized < count) : (initialized += 1) {
        const len_line = try readPlanLine(plan_bytes, &cursor);
        const arg_len = try std.fmt.parseInt(usize, len_line, 10);
        if (cursor + arg_len > plan_bytes.len) {
            return error.InvalidAdapterPlan;
        }

        argv[initialized] = try allocator.dupe(u8, plan_bytes[cursor .. cursor + arg_len]);
        cursor += arg_len;

        if (cursor >= plan_bytes.len or plan_bytes[cursor] != '\n') {
            return error.InvalidAdapterPlan;
        }
        cursor += 1;
    }

    if (cursor != plan_bytes.len) {
        return error.InvalidAdapterPlan;
    }

    return argv;
}

pub fn freeAdapterPlan(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| {
        allocator.free(arg);
    }
    allocator.free(argv);
}

fn readPlanLine(bytes: []const u8, cursor: *usize) ![]const u8 {
    if (cursor.* > bytes.len) {
        return error.InvalidAdapterPlan;
    }
    const newline_index = std.mem.indexOfScalarPos(u8, bytes, cursor.*, '\n') orelse return error.InvalidAdapterPlan;
    const line = bytes[cursor.*..newline_index];
    cursor.* = newline_index + 1;
    return line;
}

pub fn renderArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return std.mem.join(allocator, " ", argv);
}

pub fn runArgvStatus(io: std.Io, argv: []const []const u8) !u8 {
    if (argv.len == 0 or argv[0].len == 0) {
        return error.EmptyExecutionPlan;
    }

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .expand_arg0 = .expand,
    });
    errdefer child.kill(io);

    return exitCode(try child.wait(io));
}

fn runShellArgvStatus(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    if (isNixDevelopShellPlan(argv)) {
        return runQuietNixDevelopShell(allocator, io, argv);
    }
    return runArgvStatus(io, argv);
}

fn isNixDevelopShellPlan(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    if (!std.mem.eql(u8, argv[0], "nix")) return false;
    if (!std.mem.eql(u8, argv[1], "develop")) return false;
    for (argv[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--command")) return false;
    }
    return true;
}

fn runQuietNixDevelopShell(allocator: std.mem.Allocator, io: std.Io, nix_argv: []const []const u8) !u8 {
    const ready_path = try tempPath(allocator, io, "kai-dev-ready");
    defer allocator.free(ready_path);
    const ack_path = try tempPath(allocator, io, "kai-dev-ack");
    defer allocator.free(ack_path);
    deleteFileIfExists(io, ready_path);
    deleteFileIfExists(io, ack_path);
    defer deleteFileIfExists(io, ready_path);
    defer deleteFileIfExists(io, ack_path);

    const wrapper_argv = try quietNixDevelopShellArgv(allocator, ready_path, ack_path, nix_argv);
    defer allocator.free(wrapper_argv);

    const command_line = try renderArgv(allocator, nix_argv);
    defer allocator.free(command_line);
    const truncated = try spinner_mod.truncateDisplay(allocator, command_line, 96);
    defer allocator.free(truncated);
    const message = try std.fmt.allocPrint(allocator, "preparing nix dev shell: {s}", .{truncated});
    defer allocator.free(message);
    var spinner = try spinner_mod.Spinner.start(allocator, io, message, .animal);
    defer spinner.deinit();

    var child = try std.process.spawn(io, .{
        .argv = wrapper_argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .expand_arg0 = .expand,
    });
    errdefer child.kill(io);

    while (true) {
        if (fileExists(io, ready_path)) {
            spinner.stop();
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ack_path, .data = "" }) catch {};
            return exitCode(try child.wait(io));
        }

        if (try pollChildExit(&child)) |term| {
            spinner.stop();
            return exitCode(term);
        }

        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
}

const quiet_nix_develop_script =
    "ready_path=$1; ack_path=$2; shift 2; " ++
    "exec 3>&1 4>&2; " ++
    "nix --quiet --option warn-dirty false \"$@\" --command sh -c '" ++
    "ready_path=$1; ack_path=$2; " ++
    "if [ -n \"$ready_path\" ]; then : > \"$ready_path\"; i=0; while [ -n \"$ack_path\" ] && [ ! -e \"$ack_path\" ] && [ \"$i\" -lt 200 ]; do i=$((i + 1)); sleep 0.05; done; fi; " ++
    "exec 1>&3 2>&4; shell=${SHELL:-/bin/sh}; export SHELL=\"$shell\"; export KAI_SHELL=1; unset PS1 PROMPT_COMMAND BASH_ENV ENV; exec \"$shell\"' " ++
    "kai-dev-shell \"$ready_path\" \"$ack_path\" >/dev/null 2>/dev/null";

pub fn quietNixDevelopShellArgv(allocator: std.mem.Allocator, ready_path: []const u8, ack_path: []const u8, nix_argv: []const []const u8) ![]const []const u8 {
    if (!isNixDevelopShellPlan(nix_argv)) return error.UnsupportedProtocolCommand;
    const argv = try allocator.alloc([]const u8, nix_argv.len + 5);
    argv[0] = "sh";
    argv[1] = "-c";
    argv[2] = quiet_nix_develop_script;
    argv[3] = "kai-dev-wrapper";
    argv[4] = ready_path;
    argv[5] = ack_path;
    for (nix_argv[1..], 0..) |arg, index| {
        argv[6 + index] = arg;
    }
    return argv;
}

fn tempPath(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    const timestamp = std.Io.Clock.now(.real, io).nanoseconds;
    return std.fmt.allocPrint(allocator, "/tmp/{s}-{d}", .{ prefix, timestamp });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn deleteFileIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

fn pollChildExit(child: *std.process.Child) !?std.process.Child.Term {
    return switch (builtin.os.tag) {
        .linux => pollLinuxChildExit(child),
        else => null,
    };
}

fn pollLinuxChildExit(child: *std.process.Child) !?std.process.Child.Term {
    const pid = child.id orelse return null;
    var status: u32 = 0;
    const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => blk: {
            if (rc == 0) break :blk null;
            child.id = null;
            break :blk linuxStatusToTerm(status);
        },
        .INTR => null,
        else => error.UnexpectedWaitPidError,
    };
}

fn linuxStatusToTerm(status: u32) std.process.Child.Term {
    if (std.os.linux.W.IFEXITED(status)) {
        return .{ .exited = std.os.linux.W.EXITSTATUS(status) };
    }
    if (std.os.linux.W.IFSIGNALED(status)) {
        return .{ .signal = @enumFromInt(@intFromEnum(std.os.linux.W.TERMSIG(status))) };
    }
    if (std.os.linux.W.IFSTOPPED(status)) {
        return .{ .stopped = @enumFromInt(@intFromEnum(std.os.linux.W.STOPSIG(status))) };
    }
    return .{ .unknown = status };
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

test "builds adapter argv request" {
    const argv = try buildAdapterArgv(std.testing.allocator, "adapter-bin", "shell", ".", &.{ "hello", "kai quoted" });
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("adapter-bin", argv[0]);
    try std.testing.expectEqualStrings("kai.adapter.argv.v1", argv[1]);
    try std.testing.expectEqualStrings("shell", argv[2]);
    try std.testing.expectEqualStrings(".", argv[3]);
    try std.testing.expectEqualStrings("hello", argv[4]);
    try std.testing.expectEqualStrings("kai quoted", argv[5]);
}

test "parses adapter plan with spaces and newlines" {
    const plan = "kai.adapter.plan.v1\n3\n2\nsh\n2\n-c\n16\nprintf 'a b\nc d'\n";
    const argv = try parseAdapterPlan(std.testing.allocator, plan);
    defer freeAdapterPlan(std.testing.allocator, argv);

    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("printf 'a b\nc d'", argv[2]);
}

test "rejects empty adapter plan" {
    const plan = "kai.adapter.plan.v1\n0\n";
    const argv = try parseAdapterPlan(std.testing.allocator, plan);
    defer freeAdapterPlan(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 0), argv.len);
    try std.testing.expectError(error.EmptyExecutionPlan, executeProtocolCommand(std.testing.allocator, std.testing.io, "fixtures/adapters/empty-plan", "shell", ".", &.{}));
}

test "allows empty command argv for backend-native interactive shell" {
    const argv = try buildAdapterArgv(std.testing.allocator, "adapter-bin", "shell", ".", &.{});
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("adapter-bin", argv[0]);
    try std.testing.expectEqualStrings("kai.adapter.argv.v1", argv[1]);
    try std.testing.expectEqualStrings("shell", argv[2]);
    try std.testing.expectEqualStrings(".", argv[3]);
}

test "calls adapter subprocess and executes normalized argv" {
    const code = try executeProtocolCommandStatus(std.testing.allocator, std.testing.io, "fixtures/adapters/exit-plan", "shell", ".", &.{});
    try std.testing.expectEqual(@as(u8, 8), code);
}

test "executes argv with inherited stdio and returns exit code" {
    const code = try runArgvStatus(std.testing.io, &.{ "sh", "-c", "exit 7" });
    try std.testing.expectEqual(@as(u8, 7), code);
}

test "detects nix develop shell plans only before command handoff" {
    try std.testing.expect(isNixDevelopShellPlan(&.{ "nix", "develop", "--no-write-lock-file", "path:.kai/shell" }));
    try std.testing.expect(!isNixDevelopShellPlan(&.{ "nix", "develop", "--command", "echo", "hi" }));
    try std.testing.expect(!isNixDevelopShellPlan(&.{ "guix", "shell" }));
}

test "builds quiet nix develop wrapper argv" {
    const argv = try quietNixDevelopShellArgv(std.testing.allocator, "/tmp/ready", "/tmp/ack", &.{ "nix", "develop", "--no-write-lock-file", "path:.kai/shell" });
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expect(std.mem.indexOf(u8, argv[2], "nix --quiet --option warn-dirty false") != null);
    try std.testing.expectEqualStrings("kai-dev-wrapper", argv[3]);
    try std.testing.expectEqualStrings("/tmp/ready", argv[4]);
    try std.testing.expectEqualStrings("/tmp/ack", argv[5]);
    try std.testing.expectEqualStrings("develop", argv[6]);
    try std.testing.expectEqualStrings("--no-write-lock-file", argv[7]);
    try std.testing.expectEqualStrings("path:.kai/shell", argv[8]);
}
