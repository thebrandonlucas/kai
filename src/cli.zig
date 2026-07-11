//! Tiny dependency-free Kai CLI.
const std = @import("std");

const adapter_config_file = ".kai-adapter";
const default_config_file = "kai.roc";

const BuiltinAdapter = struct {
    name: []const u8,
    executable: []const u8,
};

const builtin_adapters = [_]BuiltinAdapter{
    .{ .name = "nix", .executable = "kai-adapter-nix" },
    .{ .name = "guix", .executable = "kai-adapter-guix" },
};

const ConfigCommand = struct {
    path: []const u8,
};

const Command = union(enum) {
    help,
    shell: ConfigCommand,
    build: ConfigCommand,
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

    var args = std.array_list.Managed([]const u8).init(init.gpa);
    defer args.deinit();
    while (it.next()) |arg| {
        try args.append(arg);
    }

    const command = try parseCommand(args.items);
    return executeCommand(init.gpa, init.io, init.environ_map, command);
}

fn parseCommand(args: []const []const u8) !Command {
    if (args.len == 0) return .help;
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return .help;

    if (args.len >= 1 and std.mem.eql(u8, args[0], "shell")) {
        return .{ .shell = .{ .path = try parseOptionalConfigPath(args[1..]) } };
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "build")) {
        return .{ .build = .{ .path = try parseOptionalConfigPath(args[1..]) } };
    }

    if (args.len >= 2 and std.mem.eql(u8, args[0], "adapter")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "list")) return .adapter_list;
        if (args.len == 2 and std.mem.eql(u8, args[1], "get")) return .adapter_get;
        if (args.len == 3 and std.mem.eql(u8, args[1], "set")) return .{ .adapter_set = args[2] };
    }

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
        .shell => |config| return runRocConfigSection(allocator, io, env_map, config.path, "shell"),
        .build => |config| return runRocConfigSection(allocator, io, env_map, config.path, "build"),
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
    \\  kai shell [config.roc]
    \\  kai build [config.roc]
    \\  kai adapter list
    \\  kai adapter get
    \\  kai adapter set <adapter>
    \\
    \\Config defaults to kai.roc.
    \\kai shell runs the config.shell section.
    \\kai build runs the config.machine.build section.
    \\Adapters are selected from .kai-adapter, then KAI_BACKEND_ADAPTER.
    \\Built-in adapter names: nix, guix.
    \\
;

fn runRocConfigSection(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    config_path: []const u8,
    section: []const u8,
) !u8 {
    const roc_exe = env_map.get("KAI_ROC") orelse "roc";
    const argv = rocConfigArgv(roc_exe, config_path, section);
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

fn rocConfigArgv(roc_exe: []const u8, config_path: []const u8, section: []const u8) [4][]const u8 {
    return .{ roc_exe, config_path, "--", section };
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| if (code > 255) 1 else @intCast(code),
        .signal, .stopped, .unknown => 1,
    };
}

fn selectedAdapterSetting(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
) !?Selection {
    if (try readConfiguredAdapter(allocator, io)) |setting| {
        return .{ .setting = setting, .source = adapter_config_file };
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
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, adapter_config_file, allocator, .limited(4096)) catch |err| switch (err) {
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = adapter_config_file, .data = bytes });
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

    const shell_default = try parseCommand(&.{"shell"});
    try std.testing.expectEqualStrings(default_config_file, shell_default.shell.path);
    const shell_file = try parseCommand(&.{ "shell", "examples/shell.roc" });
    try std.testing.expectEqualStrings("examples/shell.roc", shell_file.shell.path);

    const build_default = try parseCommand(&.{"build"});
    try std.testing.expectEqualStrings(default_config_file, build_default.build.path);
    const build_file = try parseCommand(&.{ "build", "examples/shell.roc" });
    try std.testing.expectEqualStrings("examples/shell.roc", build_file.build.path);

    try std.testing.expectEqual(Command.adapter_list, try parseCommand(&.{ "adapter", "list" }));
    try std.testing.expectEqual(Command.adapter_get, try parseCommand(&.{ "adapter", "get" }));

    const command = try parseCommand(&.{ "adapter", "set", "nix" });
    try std.testing.expect(std.mem.eql(u8, command.adapter_set, "nix"));
}

test "rejects unsupported commands" {
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{"version"}));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "shell", "a", "b" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "build", "a", "b" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "adapter", "delete" }));
}

test "builds roc config argv" {
    const argv = rocConfigArgv("roc", "examples/shell.roc", "build");
    try std.testing.expectEqualStrings("roc", argv[0]);
    try std.testing.expectEqualStrings("examples/shell.roc", argv[1]);
    try std.testing.expectEqualStrings("--", argv[2]);
    try std.testing.expectEqualStrings("build", argv[3]);
}

test "trims adapter config" {
    try std.testing.expectEqualStrings("nix", trimConfig(" \tnix\r\n"));
}

test "recognizes built-in adapter names" {
    try std.testing.expect(builtinAdapter("nix") != null);
    try std.testing.expect(builtinAdapter("guix") != null);
    try std.testing.expect(builtinAdapter("custom") == null);
}
