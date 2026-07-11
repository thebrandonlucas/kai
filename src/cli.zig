//! Tiny dependency-free Kai CLI.
const std = @import("std");
const protocol = @import("protocol.zig");

const config_file = ".kai-adapter";
const shell_target = ".";
const default_shell = "sh";

const BuiltinAdapter = struct {
    name: []const u8,
    executable: []const u8,
};

const builtin_adapters = [_]BuiltinAdapter{
    .{ .name = "nix", .executable = "kai-adapter-nix" },
    .{ .name = "guix", .executable = "kai-adapter-guix" },
};

const Command = union(enum) {
    help,
    shell,
    adapter_list,
    adapter_get,
    adapter_set: []const u8,
};

const Selection = struct {
    setting: []u8,
    source: []const u8,
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

    var args_buf: [4][]const u8 = undefined;
    var args_len: usize = 0;
    while (it.next()) |arg| {
        if (args_len == args_buf.len) return error.InvalidCommand;
        args_buf[args_len] = arg;
        args_len += 1;
    }

    const command = try parseCommand(args_buf[0..args_len]);
    return executeCommand(init.gpa, init.io, init.environ_map, command);
}

fn parseCommand(args: []const []const u8) !Command {
    if (args.len == 0) return .help;
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return .help;
    if (args.len == 1 and std.mem.eql(u8, args[0], "shell")) return .shell;

    if (args.len >= 2 and std.mem.eql(u8, args[0], "adapter")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "list")) return .adapter_list;
        if (args.len == 2 and std.mem.eql(u8, args[1], "get")) return .adapter_get;
        if (args.len == 3 and std.mem.eql(u8, args[1], "set")) return .{ .adapter_set = args[2] };
    }

    return error.InvalidCommand;
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
        .shell => return runShell(allocator, io, env_map),
        .adapter_list => {
            try listAdapters(allocator, io, env_map);
            return 0;
        },
        .adapter_get => {
            var selection = try selectedAdapterSetting(allocator, io, env_map);
            if (selection) |*sel| {
                defer allocator.free(sel.setting);
                try writeFmt(allocator, io, .stdout, "{s}\n", .{sel.setting});
            } else {
                try writeAll(io, .stdout, "none\n");
            }
            return 0;
        },
        .adapter_set => |adapter| {
            try validateAdapterSetting(adapter);
            try writeConfiguredAdapter(allocator, io, adapter);
            try writeFmt(allocator, io, .stdout, "{s}\n", .{adapter});
            return 0;
        },
    }
}

const help_text =
    \\kai commands:
    \\  kai help
    \\  kai shell
    \\  kai adapter list
    \\  kai adapter get
    \\  kai adapter set <adapter>
    \\
    \\Adapters are selected from .kai-adapter, then KAI_BACKEND_ADAPTER.
    \\Built-in adapter names: nix, guix.
    \\kai shell runs `sh` in target `.` through the selected adapter.
    \\
;

fn runShell(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !u8 {
    const selection = try selectedAdapterSetting(allocator, io, env_map);
    if (selection == null) return error.MissingBackendAdapter;
    defer allocator.free(selection.?.setting);

    const adapter = try resolveAdapter(allocator, io, selection.?.setting);
    defer allocator.free(adapter);

    const output = try protocol.executeProtocolCommand(
        allocator,
        io,
        adapter,
        "shell",
        shell_target,
        &.{default_shell},
    );
    defer allocator.free(output);

    try writeAll(io, .stdout, output);
    return 0;
}

fn selectedAdapterSetting(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
) !?Selection {
    if (try readConfiguredAdapter(allocator, io)) |setting| {
        return .{ .setting = setting, .source = config_file };
    }

    if (env_map.get("KAI_BACKEND_ADAPTER")) |env_adapter| {
        if (env_adapter.len != 0) {
            return .{
                .setting = try allocator.dupe(u8, env_adapter),
                .source = "KAI_BACKEND_ADAPTER",
            };
        }
    }

    return null;
}

fn readConfiguredAdapter(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, config_file, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const trimmed = trimConfig(bytes);
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn writeConfiguredAdapter(allocator: std.mem.Allocator, io: std.Io, adapter: []const u8) !void {
    const bytes = try std.fmt.allocPrint(allocator, "{s}\n", .{adapter});
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_file, .data = bytes });
}

fn validateAdapterSetting(adapter: []const u8) !void {
    if (adapter.len == 0) return error.InvalidAdapter;
    if (std.mem.indexOfAny(u8, adapter, "\r\n") != null) return error.InvalidAdapter;
}

fn trimConfig(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn resolveAdapter(allocator: std.mem.Allocator, io: std.Io, setting: []const u8) ![]u8 {
    if (builtinAdapter(setting)) |adapter| {
        if (try siblingAdapterPath(allocator, io, adapter.executable)) |path| {
            return path;
        }
        return allocator.dupe(u8, adapter.executable);
    }

    return allocator.dupe(u8, setting);
}

fn siblingAdapterPath(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) !?[]u8 {
    const bin_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(bin_dir);

    const path = try std.fs.path.join(allocator, &.{ bin_dir, executable });
    errdefer allocator.free(path);

    std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => {
            allocator.free(path);
            return null;
        },
        else => return err,
    };

    return path;
}

fn builtinAdapter(name: []const u8) ?BuiltinAdapter {
    for (builtin_adapters) |adapter| {
        if (std.mem.eql(u8, adapter.name, name)) return adapter;
    }
    return null;
}

fn listAdapters(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !void {
    const selection = try selectedAdapterSetting(allocator, io, env_map);
    defer if (selection) |sel| allocator.free(sel.setting);

    if (selection) |sel| {
        const resolved = try resolveAdapter(allocator, io, sel.setting);
        defer allocator.free(resolved);
        try writeFmt(allocator, io, .stdout, "current\t{s}\t{s}\t{s}\n", .{ sel.source, sel.setting, resolved });
    } else {
        try writeAll(io, .stdout, "current\tnone\n");
    }

    var found = false;
    for (builtin_adapters) |adapter| {
        if (try siblingAdapterPath(allocator, io, adapter.executable)) |path| {
            defer allocator.free(path);
            found = true;
            try writeFmt(allocator, io, .stdout, "{s}\t{s}\n", .{ adapter.name, path });
        }
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
    try std.testing.expectEqual(Command.shell, try parseCommand(&.{"shell"}));
    try std.testing.expectEqual(Command.adapter_list, try parseCommand(&.{ "adapter", "list" }));
    try std.testing.expectEqual(Command.adapter_get, try parseCommand(&.{ "adapter", "get" }));

    const command = try parseCommand(&.{ "adapter", "set", "nix" });
    try std.testing.expect(std.mem.eql(u8, command.adapter_set, "nix"));
}

test "rejects unsupported commands" {
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{"version"}));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "shell", "extra" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "adapter", "delete" }));
}

test "trims adapter config" {
    try std.testing.expectEqualStrings("nix", trimConfig(" \tnix\r\n"));
}

test "recognizes built-in adapter names" {
    try std.testing.expect(builtinAdapter("nix") != null);
    try std.testing.expect(builtinAdapter("guix") != null);
    try std.testing.expect(builtinAdapter("custom") == null);
}
