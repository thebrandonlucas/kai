//! Minimal Kai Roc platform host.
//!
//! Roc code emits blueprint-neutral Kai protocol commands. For config-driven
//! shell commands, this host generates blueprint state under `.kai/shell/`, sends
//! the shell request to a blueprint executable, receives a normalized argv
//! execution plan, and executes it without shell interpolation.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("roc_platform_abi.zig");
const blueprint_mod = @import("blueprint.zig");
const registry_mod = @import("command_registry.zig");
const machine = @import("machine.zig");
const protocol = @import("protocol.zig");
const shell_env = @import("shell_env.zig");

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

fn hostedKaiShell(blueprint: abi.RocStr, command: abi.RocStr, target: abi.RocStr, command_args: abi.RocList(abi.RocStr)) callconv(.c) abi.RocStr {
    const roc_host = g_roc_host.?;
    var owned_blueprint = blueprint;
    var owned_command = command;
    var owned_target = target;
    const owned_command_args = command_args;
    defer owned_blueprint.decref(roc_host);
    defer owned_command.decref(roc_host);
    defer owned_target.decref(roc_host);
    defer decrefRocStrList(owned_command_args, roc_host);

    const roc_env: *abi.RocEnv = @ptrCast(@alignCast(roc_host.env));
    const command_arg_slices = rocStringListSlices(roc_env.allocator, owned_command_args) catch |err| {
        return abi.RocStr.fromSlice(@errorName(err), roc_host);
    };
    defer roc_env.allocator.free(command_arg_slices);

    var threaded_io = std.Io.Threaded.init(roc_env.allocator, .{ .environ = g_process_environ });
    defer threaded_io.deinit();

    const env_blueprint = processBlueprintEnv();
    var selected_blueprint = blueprint_mod.selectedBlueprintWithExplicit(
        roc_env.allocator,
        threaded_io.io(),
        owned_blueprint.asSlice(),
        if (env_blueprint) |entry| entry.setting else null,
        if (env_blueprint) |entry| entry.source else null,
    ) catch |err| {
        return abi.RocStr.fromSlice(@errorName(err), roc_host);
    } orelse {
        return abi.RocStr.fromSlice(@errorName(error.MissingBlueprint), roc_host);
    };
    defer selected_blueprint.deinit(roc_env.allocator);

    switch (registry_mod.default_protocol_registry.selectImplementation(owned_command.asSlice(), selected_blueprint.blueprint, null)) {
        .ok => {},
        .blueprint_unsupported => return abi.RocStr.fromSlice(@errorName(error.UnsupportedBlueprint), roc_host),
        .command_not_registered => return abi.RocStr.fromSlice(@errorName(error.UnsupportedProtocolCommand), roc_host),
        .implementation_not_found => return abi.RocStr.fromSlice(@errorName(error.MissingProtocolImplementation), roc_host),
        .implementation_blueprint_mismatch => return abi.RocStr.fromSlice(@errorName(error.ImplementationBlueprintMismatch), roc_host),
    }

    const output = protocol.executeProtocolCommand(
        roc_env.allocator,
        threaded_io.io(),
        selected_blueprint.blueprint_executable,
        owned_command.asSlice(),
        owned_target.asSlice(),
        command_arg_slices,
    ) catch |err| {
        return abi.RocStr.fromSlice(@errorName(err), roc_host);
    };
    defer roc_env.allocator.free(output);

    return abi.RocStr.fromSlice(output, roc_host);
}

fn hostedKaiConfigShell(name: abi.RocStr, packages: abi.RocList(abi.RocStr)) callconv(.c) i32 {
    const roc_host = g_roc_host.?;
    var owned_name = name;
    const owned_packages = packages;
    defer owned_name.decref(roc_host);
    defer decrefRocStrList(owned_packages, roc_host);

    const roc_env: *abi.RocEnv = @ptrCast(@alignCast(roc_host.env));
    const package_slices = rocStringListSlices(roc_env.allocator, owned_packages) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    };
    defer roc_env.allocator.free(package_slices);

    var threaded_io = std.Io.Threaded.init(roc_env.allocator, .{ .environ = g_process_environ });
    defer threaded_io.deinit();

    const env_blueprint = processBlueprintEnv();
    var selected_blueprint = blueprint_mod.selectedBlueprintWithExplicit(
        roc_env.allocator,
        threaded_io.io(),
        "",
        if (env_blueprint) |entry| entry.setting else null,
        if (env_blueprint) |entry| entry.source else null,
    ) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    } orelse {
        writeHostError(@errorName(error.MissingBlueprint));
        return 1;
    };
    defer selected_blueprint.deinit(roc_env.allocator);

    switch (registry_mod.default_protocol_registry.selectImplementation("shell", selected_blueprint.blueprint, null)) {
        .ok => {},
        .blueprint_unsupported => {
            writeUnsupportedBlueprint(selected_blueprint.blueprintName(), "shell");
            return 1;
        },
        .command_not_registered => {
            writeHostError(@errorName(error.UnsupportedProtocolCommand));
            return 1;
        },
        .implementation_not_found => {
            writeHostError(@errorName(error.MissingProtocolImplementation));
            return 1;
        },
        .implementation_blueprint_mismatch => {
            writeHostError(@errorName(error.ImplementationBlueprintMismatch));
            return 1;
        },
    }

    const prepared = shell_env.prepare(
        roc_env.allocator,
        threaded_io.io(),
        selected_blueprint.blueprint,
        owned_name.asSlice(),
        package_slices,
    ) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    };

    if (prepared.generated_path) |path| {
        writeGeneratedShellPath(if (prepared.wrote) "wrote" else "using", path);
    }

    return protocol.executeProtocolCommandStatus(
        roc_env.allocator,
        threaded_io.io(),
        selected_blueprint.blueprint_executable,
        "shell",
        prepared.target,
        &.{},
    ) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    };
}

fn hostedKaiMachineBuild(
    hostname: abi.RocStr,
    system: abi.RocStr,
    packages: abi.RocList(abi.RocStr),
    ssh_keys: abi.RocList(abi.RocStr),
    state_version: abi.RocStr,
    image_format: abi.RocStr,
) callconv(.c) i32 {
    const roc_host = g_roc_host.?;
    var owned_hostname = hostname;
    var owned_system = system;
    const owned_packages = packages;
    const owned_ssh_keys = ssh_keys;
    var owned_state_version = state_version;
    var owned_image_format = image_format;
    defer owned_hostname.decref(roc_host);
    defer owned_system.decref(roc_host);
    defer decrefRocStrList(owned_packages, roc_host);
    defer decrefRocStrList(owned_ssh_keys, roc_host);
    defer owned_state_version.decref(roc_host);
    defer owned_image_format.decref(roc_host);

    const roc_env: *abi.RocEnv = @ptrCast(@alignCast(roc_host.env));
    const package_slices = rocStringListSlices(roc_env.allocator, owned_packages) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    };
    defer roc_env.allocator.free(package_slices);
    const ssh_key_slices = rocStringListSlices(roc_env.allocator, owned_ssh_keys) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    };
    defer roc_env.allocator.free(ssh_key_slices);

    const parsed_format = machine.ImageFormat.parse(owned_image_format.asSlice()) orelse {
        writeHostError("machine.image.format must be one of: raw, qcow2");
        return 2;
    };

    var threaded_io = std.Io.Threaded.init(roc_env.allocator, .{ .environ = g_process_environ });
    defer threaded_io.deinit();

    const env_blueprint = processBlueprintEnv();
    var selected_blueprint = blueprint_mod.selectedBlueprintWithExplicit(
        roc_env.allocator,
        threaded_io.io(),
        "",
        if (env_blueprint) |entry| entry.setting else null,
        if (env_blueprint) |entry| entry.source else null,
    ) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    } orelse {
        writeHostError(@errorName(error.MissingBlueprint));
        return 1;
    };
    defer selected_blueprint.deinit(roc_env.allocator);

    if (selected_blueprint.blueprint != .nix) {
        writeUnsupportedBlueprint(selected_blueprint.blueprintName(), "machine.build");
        return 1;
    }

    return machine.build(roc_env.allocator, threaded_io.io(), .{
        .hostname = owned_hostname.asSlice(),
        .system = owned_system.asSlice(),
        .packages = package_slices,
        .ssh_keys = ssh_key_slices,
        .state_version = owned_state_version.asSlice(),
        .image_format = parsed_format,
    }) catch |err| {
        writeHostError(@errorName(err));
        return 1;
    };
}

fn writeHostStdout(message: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, message) catch return;
}

fn writeGeneratedShellPath(status: []const u8, path: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, status) catch return;
    stdout.writeStreamingAll(io, " ") catch return;
    stdout.writeStreamingAll(io, path) catch return;
    stdout.writeStreamingAll(io, "\n") catch return;
}

fn writeHostError(message: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, "kai: ") catch return;
    stderr.writeStreamingAll(io, message) catch return;
    stderr.writeStreamingAll(io, "\n") catch return;
}

fn writeUnsupportedBlueprint(active_blueprint: []const u8, command_name: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, "kai: blueprint ") catch return;
    stderr.writeStreamingAll(io, active_blueprint) catch return;
    stderr.writeStreamingAll(io, " does not support protocol command ") catch return;
    stderr.writeStreamingAll(io, command_name) catch return;
    stderr.writeStreamingAll(io, "\n") catch return;
}

comptime {
    if (!builtin.is_test) {
        @export(&hostedKaiShell, .{ .name = "roc_kai_shell", .visibility = .hidden });
        @export(&hostedKaiConfigShell, .{ .name = "roc_kai_config_shell", .visibility = .hidden });
        @export(&hostedKaiMachineBuild, .{ .name = "roc_kai_machine_build", .visibility = .hidden });
        @export(&hostedStdoutLine, .{ .name = "roc_stdout_line", .visibility = .hidden });

        @export(&hostAlloc, .{ .name = "roc_alloc", .visibility = .hidden });
        @export(&hostDealloc, .{ .name = "roc_dealloc", .visibility = .hidden });
        @export(&hostRealloc, .{ .name = "roc_realloc", .visibility = .hidden });
        @export(&hostDbg, .{ .name = "roc_dbg", .visibility = .hidden });
        @export(&hostExpectFailed, .{ .name = "roc_expect_failed", .visibility = .hidden });
        @export(&hostCrashed, .{ .name = "roc_crashed", .visibility = .hidden });
    }
}

const ProcessEnvBlueprint = struct {
    setting: []const u8,
    source: []const u8,
};

fn processBlueprintEnv() ?ProcessEnvBlueprint {
    if (processEnvValue(blueprint_mod.env_blueprint_name)) |setting| {
        if (setting.len != 0) return .{ .setting = setting, .source = blueprint_mod.env_blueprint_name };
    }
    if (processEnvValue(blueprint_mod.legacy_env_adapter_name)) |setting| {
        if (setting.len != 0) return .{ .setting = setting, .source = blueprint_mod.legacy_env_adapter_name };
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
