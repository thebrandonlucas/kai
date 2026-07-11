//! Backend-neutral Kai shell protocol execution.
//!
//! This module contains the generic host/CLI adapter protocol plumbing. It does
//! not know about any specific backend; backend lowering stays in Roc adapters.
const std = @import("std");

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
    if (!std.mem.eql(u8, command, "shell")) {
        return error.UnsupportedProtocolCommand;
    }
    if (command_args.len == 0) {
        return error.EmptyShellCommand;
    }

    const adapter_argv = try buildAdapterArgv(allocator, adapter, command, target, command_args);
    defer allocator.free(adapter_argv);

    const plan_bytes = try runAdapter(allocator, io, adapter_argv);
    defer allocator.free(plan_bytes);

    const plan_argv = try parseAdapterPlan(allocator, plan_bytes);
    defer freeAdapterPlan(allocator, plan_argv);

    if (plan_argv.len == 0) {
        return error.EmptyExecutionPlan;
    }

    return runArgv(allocator, io, plan_argv);
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

pub fn runArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
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
            return std.fmt.allocPrint(
                allocator,
                "kai: subprocess exited with status {d}\nstdout:\n{s}\nstderr:\n{s}",
                .{ code, result.stdout, result.stderr },
            );
        },
        .signal => |signal| return std.fmt.allocPrint(
            allocator,
            "kai: subprocess terminated by signal {d}\nstdout:\n{s}\nstderr:\n{s}",
            .{ @intFromEnum(signal), result.stdout, result.stderr },
        ),
        .stopped => |signal| return std.fmt.allocPrint(
            allocator,
            "kai: subprocess stopped by signal {d}\nstdout:\n{s}\nstderr:\n{s}",
            .{ @intFromEnum(signal), result.stdout, result.stderr },
        ),
        .unknown => |status| return std.fmt.allocPrint(
            allocator,
            "kai: subprocess ended with unknown status {d}\nstdout:\n{s}\nstderr:\n{s}",
            .{ status, result.stdout, result.stderr },
        ),
    }
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
    try std.testing.expectError(error.EmptyExecutionPlan, executeProtocolCommand(std.testing.allocator, std.testing.io, "fixtures/adapters/empty-plan", "shell", ".", &.{"ignored"}));
}

test "requires a non-interactive shell command" {
    try std.testing.expectError(error.EmptyShellCommand, executeProtocolCommand(std.testing.allocator, std.testing.io, "fixtures/adapters/static-plan", "shell", ".", &.{}));
}

test "calls adapter subprocess and executes normalized argv" {
    const output = try executeProtocolCommand(std.heap.page_allocator, std.testing.io, "fixtures/adapters/static-plan", "shell", ".", &.{"ignored"});
    defer std.heap.page_allocator.free(output);
    try std.testing.expectEqualStrings("kai-adapter-ok", output);
}

test "executes argv and captures stdout" {
    const output = try runArgv(std.heap.page_allocator, std.testing.io, &.{ "sh", "-c", "printf kai-ok" });
    defer std.heap.page_allocator.free(output);
    try std.testing.expectEqualStrings("kai-ok", output);
}
