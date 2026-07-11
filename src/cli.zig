//! Tiny dependency-free Kai CLI.
const std = @import("std");
const backend_mod = @import("backend.zig");
const registry_mod = @import("command_registry.zig");

const default_config_file = "kai.roc";

const ConfigCommand = struct {
    cli_name: []const u8,
    path: []const u8,
};

const Command = union(enum) {
    help,
    protocol: ConfigCommand,
    adapter_list,
    adapter_get,
    adapter_set: []const u8,
    unavailable: []const u8,
};

const DispatchPlan = struct {
    command_name: []const u8,
    implementation_id: []const u8,
    active_backend: backend_mod.Backend,
    config_path: []const u8,
};

const DispatchResult = union(enum) {
    ok: DispatchPlan,
    command_not_available,
    unsupported_backend,
    implementation_not_found,
    implementation_backend_mismatch: *const registry_mod.CommandImplementation,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        writeFmt(init.gpa, init.io, .stderr, "kai: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    _ = it.next(); // argv[0]

    var args = std.array_list.Managed([]const u8).init(init.gpa);
    defer args.deinit();
    while (it.next()) |arg| {
        try args.append(arg);
    }

    const command = parseCommand(args.items) catch {
        try writeAll(init.io, .stderr, "kai: invalid command usage\n");
        return 1;
    };
    return executeCommand(init.gpa, init.io, init.environ_map, command);
}

fn parseCommand(args: []const []const u8) !Command {
    if (args.len == 0) return .help;
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return .help;

    if (args.len >= 1 and (std.mem.eql(u8, args[0], "shell") or std.mem.eql(u8, args[0], "build"))) {
        return .{ .protocol = .{ .cli_name = args[0], .path = try parseOptionalConfigPath(args[1..]) } };
    }

    if (args.len >= 2 and (std.mem.eql(u8, args[0], "backend") or std.mem.eql(u8, args[0], "adapter"))) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "list")) return .adapter_list;
        if (args.len == 2 and std.mem.eql(u8, args[1], "get")) return .adapter_get;
        if (args.len == 3 and std.mem.eql(u8, args[1], "set")) return .{ .adapter_set = args[2] };
        return error.InvalidCommand;
    }

    if (args.len >= 1) return .{ .unavailable = args[0] };
    return error.InvalidCommand;
}

fn parseOptionalConfigPath(args: []const []const u8) ![]const u8 {
    return switch (args.len) {
        0 => default_config_file,
        1 => args[0],
        else => error.InvalidCommand,
    };
}

fn executeCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    command: Command,
) !u8 {
    switch (command) {
        .help => {
            try writeAll(io, .stdout, help_text);
            return 0;
        },
        .protocol => |config| return dispatchProtocolCommand(allocator, io, env_map, config),
        .adapter_list => {
            try listAdapters(allocator, io, env_map);
            return 0;
        },
        .adapter_get => {
            var selection = try backend_mod.selectedBackend(allocator, io, env_map);
            if (selection) |*sel| {
                defer sel.deinit(allocator);
                try writeFmt(allocator, io, .stdout, "{s}\n", .{sel.setting});
            } else {
                try writeAll(io, .stdout, "none\n");
            }
            return 0;
        },
        .adapter_set => |adapter| {
            try backend_mod.validateBackendSetting(adapter);
            try backend_mod.writeConfiguredBackend(allocator, io, adapter);
            try writeFmt(allocator, io, .stdout, "{s}\n", .{adapter});
            return 0;
        },
        .unavailable => |name| {
            try writeFmt(allocator, io, .stderr, "kai: command not available: {s}\n", .{name});
            return 1;
        },
    }
}

const help_text =
    \\kai commands:
    \\  kai help
    \\  kai shell [config.roc]
    \\  kai build [config.roc]
    \\  kai backend list
    \\  kai backend get
    \\  kai backend set <backend-or-adapter>
    \\  kai adapter ...  # legacy alias for kai backend ...
    \\
    \\Config defaults to kai.roc.
    \\kai shell dispatches protocol command shell.
    \\kai build dispatches protocol command machine.build.
    \\Backend selection is read from .kai-backend, legacy .kai-adapter, then KAI_BACKEND_ADAPTER.
    \\Built-in backend names: nix, guix.
    \\
;

fn dispatchProtocolCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    config: ConfigCommand,
) !u8 {
    var active = try backend_mod.selectedBackend(allocator, io, env_map) orelse {
        try writeAll(io, .stderr, "kai: missing active backend; run `kai backend set nix` or set KAI_BACKEND_ADAPTER\n");
        return 1;
    };
    defer active.deinit(allocator);

    const override_id = try implementationOverride(allocator, env_map, config.cli_name);
    defer if (override_id) |id| allocator.free(id);

    const result = planProtocolDispatch(
        registry_mod.default_protocol_registry,
        config.cli_name,
        config.path,
        active.backend,
        override_id,
    );

    return switch (result) {
        .ok => |plan| runRocConfigProtocolCommand(allocator, io, env_map, plan.config_path, plan.command_name),
        .command_not_available, .implementation_not_found => blk: {
            try writeFmt(allocator, io, .stderr, "kai: command not available: {s}\n", .{config.cli_name});
            break :blk 1;
        },
        .unsupported_backend => blk: {
            const command = registry_mod.default_protocol_registry.lookup(config.cli_name).?;
            try writeFmt(allocator, io, .stderr, "kai: backend {s} does not support protocol command {s}\n", .{ active.backendName(), command.name });
            break :blk 1;
        },
        .implementation_backend_mismatch => |implementation| blk: {
            const command = registry_mod.default_protocol_registry.lookup(config.cli_name).?;
            try writeFmt(
                allocator,
                io,
                .stderr,
                "kai: implementation backend mismatch: command {s} requires {s}, active backend is {s}\n",
                .{ command.name, implementation.backend.name(), active.backendName() },
            );
            break :blk 1;
        },
    };
}

fn planProtocolDispatch(
    registry: registry_mod.ProtocolRegistry,
    cli_name: []const u8,
    config_path: []const u8,
    active_backend: backend_mod.Backend,
    override_id: ?[]const u8,
) DispatchResult {
    const command = registry.lookup(cli_name) orelse return .command_not_available;
    const selected = registry.selectImplementation(command.name, active_backend, override_id);
    return switch (selected) {
        .ok => |implementation| .{ .ok = .{
            .command_name = command.name,
            .implementation_id = implementation.id,
            .active_backend = active_backend,
            .config_path = config_path,
        } },
        .command_not_registered => .command_not_available,
        .backend_unsupported => .unsupported_backend,
        .implementation_not_found => .implementation_not_found,
        .implementation_backend_mismatch => |implementation| .{ .implementation_backend_mismatch = implementation },
    };
}

fn implementationOverride(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cli_name: []const u8,
) !?[]u8 {
    const command = registry_mod.default_protocol_registry.lookup(cli_name) orelse return null;
    const env_name = try registry_mod.cliImplementationOverrideName(allocator, command.name);
    defer allocator.free(env_name);
    if (env_map.get(env_name)) |value| {
        if (value.len != 0) return try allocator.dupe(u8, value);
    }
    return null;
}

fn runRocConfigProtocolCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    config_path: []const u8,
    command_name: []const u8,
) !u8 {
    const roc_exe = env_map.get("KAI_ROC") orelse "roc";
    const argv = rocConfigArgv(roc_exe, config_path, command_name);
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try writeAll(io, .stdout, result.stdout);
    try writeAll(io, .stderr, result.stderr);

    return exitCode(result.term);
}

fn rocConfigArgv(roc_exe: []const u8, config_path: []const u8, command_name: []const u8) [4][]const u8 {
    return .{ roc_exe, config_path, "--", command_name };
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| if (code > 255) 1 else @intCast(code),
        .signal, .stopped, .unknown => 1,
    };
}

fn listAdapters(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !void {
    var selection = try backend_mod.selectedBackend(allocator, io, env_map);
    if (selection) |*sel| {
        defer sel.deinit(allocator);
        try writeFmt(allocator, io, .stdout, "current\t{s}\t{s}\t{s}\tbackend={s}\n", .{ sel.source, sel.setting, sel.adapter_executable, sel.backendName() });
    } else {
        try writeAll(io, .stdout, "current\tnone\n");
    }

    var found = false;
    for (backend_mod.builtin_adapters) |adapter| {
        const resolved = try backend_mod.resolveAdapter(allocator, io, adapter.name);
        defer allocator.free(resolved);
        found = true;
        try writeFmt(allocator, io, .stdout, "{s}\t{s}\tbackend={s}\n", .{ adapter.name, resolved, adapter.backend.name() });
    }

    if (!found) {
        try writeAll(io, .stdout, "built\tnone-found-next-to-kai\n");
    }
}

const Stream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    try file.writeStreamingAll(io, bytes);
}

fn writeFmt(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: Stream,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try writeAll(io, stream, bytes);
}

test "parses supported commands" {
    try std.testing.expectEqual(Command.help, try parseCommand(&.{"help"}));

    const shell_default = try parseCommand(&.{"shell"});
    try std.testing.expectEqualStrings("shell", shell_default.protocol.cli_name);
    try std.testing.expectEqualStrings(default_config_file, shell_default.protocol.path);
    const shell_file = try parseCommand(&.{ "shell", "examples/shell.roc" });
    try std.testing.expectEqualStrings("examples/shell.roc", shell_file.protocol.path);

    const build_default = try parseCommand(&.{"build"});
    try std.testing.expectEqualStrings("build", build_default.protocol.cli_name);
    try std.testing.expectEqualStrings(default_config_file, build_default.protocol.path);
    const build_file = try parseCommand(&.{ "build", "examples/shell.roc" });
    try std.testing.expectEqualStrings("examples/shell.roc", build_file.protocol.path);

    try std.testing.expectEqual(Command.adapter_list, try parseCommand(&.{ "backend", "list" }));
    try std.testing.expectEqual(Command.adapter_get, try parseCommand(&.{ "backend", "get" }));
    try std.testing.expectEqual(Command.adapter_list, try parseCommand(&.{ "adapter", "list" }));

    const command = try parseCommand(&.{ "backend", "set", "nix" });
    try std.testing.expect(std.mem.eql(u8, command.adapter_set, "nix"));
}

test "rejects invalid command usage" {
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "shell", "a", "b" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "build", "a", "b" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "adapter", "delete" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "backend", "delete" }));
}

test "preserves unavailable command name" {
    const command = try parseCommand(&.{"deploy"});
    try std.testing.expectEqualStrings("deploy", command.unavailable);
}

test "builds roc config argv with protocol command name" {
    const argv = rocConfigArgv("roc", "examples/shell.roc", "machine.build");
    try std.testing.expectEqualStrings("roc", argv[0]);
    try std.testing.expectEqualStrings("examples/shell.roc", argv[1]);
    try std.testing.expectEqualStrings("--", argv[2]);
    try std.testing.expectEqualStrings("machine.build", argv[3]);
}

test "plans shell command dispatch" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "shell", "examples/shell.roc", .nix, null);
    switch (result) {
        .ok => |plan| {
            try std.testing.expectEqualStrings("shell", plan.command_name);
            try std.testing.expectEqualStrings("shell.default.nix", plan.implementation_id);
            try std.testing.expectEqual(backend_mod.Backend.nix, plan.active_backend);
        },
        else => return error.TestExpectedShellDispatch,
    }
}

test "plans build alias dispatch to machine.build" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "build", "kai.roc", .nix, null);
    switch (result) {
        .ok => |plan| {
            try std.testing.expectEqualStrings("machine.build", plan.command_name);
            try std.testing.expectEqualStrings("machine.build.default.nix", plan.implementation_id);
        },
        else => return error.TestExpectedBuildDispatch,
    }
}

test "reports unsupported backend for machine build on guix" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "build", "kai.roc", .guix, null);
    try std.testing.expectEqual(DispatchResult.unsupported_backend, result);
}

test "reports command not registered" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "deploy", "kai.roc", .nix, null);
    try std.testing.expectEqual(DispatchResult.command_not_available, result);
}

test "reports implementation backend mismatch" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "shell", "kai.roc", .guix, "shell.default.nix");
    switch (result) {
        .implementation_backend_mismatch => |implementation| try std.testing.expectEqualStrings("shell.default.nix", implementation.id),
        else => return error.TestExpectedBackendMismatch,
    }
}
