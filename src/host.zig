//! Minimal Kai Roc platform host.
//!
//! Roc code emits a backend-neutral protocol command (`shell`). This Zig host
//! lowers that command to a selected backend command line.
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

fn hostedKaiShell(backend: abi.RocStr, command: abi.RocStr, target: abi.RocStr) callconv(.c) abi.RocStr {
    const roc_host = g_roc_host.?;
    var owned_backend = backend;
    var owned_command = command;
    var owned_target = target;
    defer owned_backend.decref(roc_host);
    defer owned_command.decref(roc_host);
    defer owned_target.decref(roc_host);

    const roc_env: *abi.RocEnv = @ptrCast(@alignCast(roc_host.env));
    const rendered = lowerProtocolCommand(roc_env.allocator, owned_backend.asSlice(), owned_command.asSlice(), owned_target.asSlice()) catch |err| {
        return abi.RocStr.fromSlice(@errorName(err), roc_host);
    };
    defer roc_env.allocator.free(rendered);

    return abi.RocStr.fromSlice(rendered, roc_host);
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

pub fn lowerProtocolCommand(allocator: std.mem.Allocator, backend: []const u8, command: []const u8, target: []const u8) ![]u8 {
    if (!std.mem.eql(u8, command, "shell")) {
        return std.fmt.allocPrint(allocator, "kai: unsupported protocol command '{s}'", .{command});
    }

    return lowerShellCommand(allocator, backend, target);
}

pub fn lowerShellCommand(allocator: std.mem.Allocator, backend: []const u8, target: []const u8) ![]u8 {
    const has_target = target.len != 0;

    if (std.mem.eql(u8, backend, "nix")) {
        return if (has_target)
            std.fmt.allocPrint(allocator, "nix develop {s}", .{target})
        else
            std.fmt.allocPrint(allocator, "nix develop", .{});
    }

    if (std.mem.eql(u8, backend, "guix")) {
        return if (has_target)
            std.fmt.allocPrint(allocator, "guix shell {s}", .{target})
        else
            std.fmt.allocPrint(allocator, "guix shell", .{});
    }

    return std.fmt.allocPrint(allocator, "kai: unsupported backend '{s}'", .{backend});
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

test "lowers shell protocol to nix develop" {
    const rendered = try lowerProtocolCommand(std.testing.allocator, "nix", "shell", ".");
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("nix develop .", rendered);
}

test "lowers shell protocol to guix shell" {
    const rendered = try lowerProtocolCommand(std.testing.allocator, "guix", "shell", ".");
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("guix shell .", rendered);
}
