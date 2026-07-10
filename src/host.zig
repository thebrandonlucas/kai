//! Minimal Kai Roc platform host.
//!
//! Roc code emits a backend-neutral protocol command (`shell`). This Zig host
//! lowers that command to backend-specific argv and executes it.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("roc_platform_abi.zig");

pub const std_options: std.Options = .{
    .allow_stack_tracing = false,
};

const HostEnv = struct {
    gpa: std.heap.DebugAllocator(.{}),
    roc_env: abi.RocEnv,
};

extern fn roc_main(args: abi.RocList(abi.RocStr)) callconv(.c) i32;

var g_roc_host: ?*abi.RocHost = null;

comptime {
    if (!builtin.is_test) {
        @export(&main, .{ .name = "main" });

        if (builtin.os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

fn __main() callconv(.c) void {}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return platformMain(@intCast(argc), argv);
}

fn hostedStdoutLine(str: abi.RocStr) callconv(.c) void {
    const roc_host = g_roc_host.?;
    var owned = str;
    defer owned.decref(roc_host);

    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, owned.asSlice()) catch return;
    stdout.writeStreamingAll(io, "\n") catch return;
}

fn hostedKaiShell(backend: abi.RocStr, command: abi.RocStr, target: abi.RocStr, command_args: abi.RocList(abi.RocStr)) callconv(.c) abi.RocStr {
    const roc_host = g_roc_host.?;
    var owned_backend = backend;
    var owned_command = command;
    var owned_target = target;
    const owned_command_args = command_args;
    defer owned_backend.decref(roc_host);
    defer owned_command.decref(roc_host);
    defer owned_target.decref(roc_host);
    defer decrefRocStrList(owned_command_args, roc_host);

    const roc_env: *abi.RocEnv = @ptrCast(@alignCast(roc_host.env));
    const command_arg_slices = rocStringListSlices(roc_env.allocator, owned_command_args) catch |err| {
        return abi.RocStr.fromSlice(@errorName(err), roc_host);
    };
    defer roc_env.allocator.free(command_arg_slices);

    const output = executeProtocolCommand(
        roc_env.allocator,
        std.Io.Threaded.global_single_threaded.io(),
        owned_backend.asSlice(),
        owned_command.asSlice(),
        owned_target.asSlice(),
        command_arg_slices,
    ) catch |err| {
        return abi.RocStr.fromSlice(@errorName(err), roc_host);
    };
    defer roc_env.allocator.free(output);

    return abi.RocStr.fromSlice(output, roc_host);
}

comptime {
    if (!builtin.is_test) {
        @export(&hostedKaiShell, .{ .name = "roc_kai_shell", .visibility = .hidden });
        @export(&hostedStdoutLine, .{ .name = "roc_stdout_line", .visibility = .hidden });

        @export(&hostAlloc, .{ .name = "roc_alloc", .visibility = .hidden });
        @export(&hostDealloc, .{ .name = "roc_dealloc", .visibility = .hidden });
        @export(&hostRealloc, .{ .name = "roc_realloc", .visibility = .hidden });
        @export(&hostDbg, .{ .name = "roc_dbg", .visibility = .hidden });
        @export(&hostExpectFailed, .{ .name = "roc_expect_failed", .visibility = .hidden });
        @export(&hostCrashed, .{ .name = "roc_crashed", .visibility = .hidden });
    }
}

const LoweredCommand = struct {
    argv: []const []const u8,

    fn deinit(self: LoweredCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
    }
};

pub fn executeProtocolCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: []const u8,
    command: []const u8,
    target: []const u8,
    command_args: []const []const u8,
) ![]u8 {
    const lowered = try lowerProtocolCommand(allocator, backend, command, target, command_args);
    defer lowered.deinit(allocator);
    return runArgv(allocator, io, lowered.argv);
}

pub fn lowerProtocolCommand(
    allocator: std.mem.Allocator,
    backend: []const u8,
    command: []const u8,
    target: []const u8,
    command_args: []const []const u8,
) !LoweredCommand {
    if (!std.mem.eql(u8, command, "shell")) {
        return error.UnsupportedProtocolCommand;
    }

    return lowerShellCommand(allocator, backend, target, command_args);
}

pub fn lowerShellCommand(
    allocator: std.mem.Allocator,
    backend: []const u8,
    target: []const u8,
    command_args: []const []const u8,
) !LoweredCommand {
    if (command_args.len == 0) {
        return error.EmptyShellCommand;
    }

    if (std.mem.eql(u8, backend, "nix")) {
        return lowerNixShellCommand(allocator, target, command_args);
    }

    if (std.mem.eql(u8, backend, "guix")) {
        return lowerGuixShellCommand(allocator, target, command_args);
    }

    return error.UnsupportedBackend;
}

fn lowerNixShellCommand(
    allocator: std.mem.Allocator,
    target: []const u8,
    command_args: []const []const u8,
) !LoweredCommand {
    const has_target = target.len != 0;
    const target_arg_count: usize = if (has_target) 1 else 0;
    const argv = try allocator.alloc([]const u8, 4 + target_arg_count + command_args.len);
    var index: usize = 0;
    argv[index] = "nix";
    index += 1;
    argv[index] = "develop";
    index += 1;
    argv[index] = "--no-write-lock-file";
    index += 1;
    if (has_target) {
        argv[index] = target;
        index += 1;
    }
    argv[index] = "--command";
    index += 1;
    copyArgvTail(argv, index, command_args);
    return .{ .argv = argv };
}

fn lowerGuixShellCommand(
    allocator: std.mem.Allocator,
    target: []const u8,
    command_args: []const []const u8,
) !LoweredCommand {
    const has_target = target.len != 0;
    const uses_manifest = has_target and std.mem.endsWith(u8, target, ".scm");
    const target_arg_count: usize = if (uses_manifest) 2 else if (has_target) 1 else 0;
    const argv = try allocator.alloc([]const u8, 3 + target_arg_count + command_args.len);
    var index: usize = 0;
    argv[index] = "guix";
    index += 1;
    argv[index] = "shell";
    index += 1;
    if (uses_manifest) {
        argv[index] = "-m";
        index += 1;
        argv[index] = target;
        index += 1;
    } else if (has_target) {
        argv[index] = target;
        index += 1;
    }
    argv[index] = "--";
    index += 1;
    copyArgvTail(argv, index, command_args);
    return .{ .argv = argv };
}

fn copyArgvTail(argv: [][]const u8, start: usize, tail: []const []const u8) void {
    for (tail, 0..) |arg, offset| {
        argv[start + offset] = arg;
    }
}

pub fn renderArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return std.mem.join(allocator, " ", argv);
}

pub fn runArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
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

fn rocStringListSlices(allocator: std.mem.Allocator, list: abi.RocList(abi.RocStr)) ![]const []const u8 {
    const items = list.items();
    const slices = try allocator.alloc([]const u8, items.len);
    for (0..items.len) |i| {
        slices[i] = (&items[i]).asSlice();
    }
    return slices;
}

fn decrefRocStrList(list: abi.RocList(abi.RocStr), roc_host: *abi.RocHost) void {
    for (list.items()) |item| {
        var owned = item;
        owned.decref(roc_host);
    }
    list.decref(roc_host);
}

fn hostAlloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocAlloc(g_roc_host.?, length, alignment);
}

fn hostDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    abi.DefaultAllocators.rocDealloc(g_roc_host.?, ptr, alignment);
}

fn hostRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocRealloc(g_roc_host.?, ptr, new_length, alignment);
}

fn hostDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocDbg(g_roc_host.?, bytes, len);
}

fn hostExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocExpectFailed(g_roc_host.?, bytes, len);
}

fn hostCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocCrashed(g_roc_host.?, bytes, len);
}

fn platformMain(argc: usize, argv: [*][*:0]u8) c_int {
    var host_env = HostEnv{
        .gpa = std.heap.DebugAllocator(.{}){},
        .roc_env = undefined,
    };
    host_env.roc_env = .{
        .allocator = host_env.gpa.allocator(),
        .roc_io = abi.RocIo.default(),
    };

    var roc_host = abi.makeRocHost(&host_env.roc_env);
    g_roc_host = &roc_host;

    const args_list = buildStrArgsList(argc, argv, &roc_host);
    const exit_code = roc_main(args_list);

    const leak_status = host_env.gpa.deinit();
    if (leak_status == .leak) {
        std.process.exit(1);
    }

    return exit_code;
}

fn buildStrArgsList(argc: usize, argv: [*][*:0]u8, roc_host: *abi.RocHost) abi.RocList(abi.RocStr) {
    if (argc == 0) {
        return abi.RocList(abi.RocStr).empty();
    }

    const args_list = abi.RocList(abi.RocStr).allocate(argc, roc_host);
    const args_ptr: [*]abi.RocStr = args_list.elements_ptr.?;

    for (0..argc) |i| {
        const arg_cstr = argv[i];
        const arg_len = std.mem.len(arg_cstr);
        args_ptr[i] = abi.RocStr.fromSlice(arg_cstr[0..arg_len], roc_host);
    }

    return args_list;
}

test "lowers shell protocol to nix develop argv" {
    const lowered = try lowerProtocolCommand(std.testing.allocator, "nix", "shell", ".", &.{ "guix", "--version" });
    defer lowered.deinit(std.testing.allocator);
    const rendered = try renderArgv(std.testing.allocator, lowered.argv);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("nix develop --no-write-lock-file . --command guix --version", rendered);
}

test "lowers shell protocol to guix shell argv" {
    const lowered = try lowerProtocolCommand(std.testing.allocator, "guix", "shell", "fixtures/shell/manifest.scm", &.{ "hello", "--version" });
    defer lowered.deinit(std.testing.allocator);
    const rendered = try renderArgv(std.testing.allocator, lowered.argv);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("guix shell -m fixtures/shell/manifest.scm -- hello --version", rendered);
}

test "requires a non-interactive shell command" {
    try std.testing.expectError(error.EmptyShellCommand, lowerProtocolCommand(std.testing.allocator, "nix", "shell", ".", &.{}));
}

test "executes argv and captures stdout" {
    const output = try runArgv(std.heap.page_allocator, std.testing.io, &.{ "sh", "-c", "printf kai-ok" });
    defer std.heap.page_allocator.free(output);
    try std.testing.expectEqualStrings("kai-ok", output);
}
