//! Minimal Kai Roc platform host.
//!
//! Roc code emits a backend-neutral protocol command (`shell`). This Zig host
//! sends that command to a backend adapter executable, receives a normalized
//! argv execution plan, and executes it without shell interpolation.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("roc_platform_abi.zig");
const protocol = @import("protocol.zig");

pub const std_options: std.Options = .{
    .allow_stack_tracing = false,
};

const HostEnv = struct {
    gpa: std.heap.DebugAllocator(.{}),
    roc_env: abi.RocEnv,
};

extern fn roc_main(args: abi.RocList(abi.RocStr)) callconv(.c) i32;

var g_roc_host: ?*abi.RocHost = null;
var g_process_environ: std.process.Environ = .empty;

comptime {
    if (!builtin.is_test) {
        @export(&main, .{ .name = "main" });

        if (builtin.os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

fn __main() callconv(.c) void {}

fn main(argc: c_int, argv: [*][*:0]u8, envp: [*:null]?[*:0]u8) callconv(.c) c_int {
    g_process_environ = processEnvironFromEnvp(envp);
    return platformMain(@intCast(argc), argv);
}

fn processEnvironFromEnvp(envp: [*:null]?[*:0]u8) std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => blk: {
            var env_count: usize = 0;
            while (envp[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = envp[0..env_count :null] } };
        },
    };
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

fn hostedKaiShell(adapter: abi.RocStr, command: abi.RocStr, target: abi.RocStr, command_args: abi.RocList(abi.RocStr)) callconv(.c) abi.RocStr {
    const roc_host = g_roc_host.?;
    var owned_adapter = adapter;
    var owned_command = command;
    var owned_target = target;
    const owned_command_args = command_args;
    defer owned_adapter.decref(roc_host);
    defer owned_command.decref(roc_host);
    defer owned_target.decref(roc_host);
    defer decrefRocStrList(owned_command_args, roc_host);

    const roc_env: *abi.RocEnv = @ptrCast(@alignCast(roc_host.env));
    const command_arg_slices = rocStringListSlices(roc_env.allocator, owned_command_args) catch |err| {
        return abi.RocStr.fromSlice(@errorName(err), roc_host);
    };
    defer roc_env.allocator.free(command_arg_slices);

    const selected_adapter = selectedAdapter(owned_adapter.asSlice()) orelse {
        return abi.RocStr.fromSlice(@errorName(error.MissingBackendAdapter), roc_host);
    };

    var threaded_io = std.Io.Threaded.init(roc_env.allocator, .{ .environ = g_process_environ });
    defer threaded_io.deinit();

    const output = protocol.executeProtocolCommand(
        roc_env.allocator,
        threaded_io.io(),
        selected_adapter,
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

fn selectedAdapter(explicit_adapter: []const u8) ?[]const u8 {
    if (explicit_adapter.len != 0) {
        return explicit_adapter;
    }
    if (processEnvValue("KAI_BACKEND_ADAPTER")) |env_adapter| {
        if (env_adapter.len != 0) return env_adapter;
    }
    return null;
}

fn processEnvValue(name: []const u8) ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => null,
        else => blk: {
            const view = g_process_environ.block.view();
            for (view.slice) |entry_z| {
                const entry = std.mem.span(entry_z);
                if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) {
                    break :blk entry[name.len + 1 ..];
                }
            }
            break :blk null;
        },
    };
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
