const std = @import("std");

pub const adapter_config_file = ".kai-adapter";
pub const env_adapter_name = "KAI_BACKEND_ADAPTER";

pub const Backend = enum {
    nix,
    guix,
    adapter,

    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .nix => "nix",
            .guix => "guix",
            .adapter => "adapter",
        };
    }

    pub fn parse(value: []const u8) ?Backend {
        const trimmed = trimConfig(value);
        if (std.mem.eql(u8, trimmed, "nix")) return .nix;
        if (std.mem.eql(u8, trimmed, "guix")) return .guix;
        if (std.mem.eql(u8, trimmed, "adapter")) return .adapter;
        return null;
    }
};

pub const BuiltinAdapter = struct {
    backend: Backend,
    name: []const u8,
    executable: []const u8,
};

pub const builtin_adapters = [_]BuiltinAdapter{
    .{ .backend = .nix, .name = "nix", .executable = "kai-adapter-nix" },
    .{ .backend = .guix, .name = "guix", .executable = "kai-adapter-guix" },
};

pub const Selection = struct {
    backend: Backend,
    setting: []u8,
    source: []const u8,
    adapter_executable: []u8,

    pub fn deinit(self: Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.setting);
        allocator.free(self.adapter_executable);
    }

    pub fn backendName(self: Selection) []const u8 {
        return self.backend.name();
    }
};

pub fn selectedBackend(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: ?*std.process.Environ.Map,
) !?Selection {
    return selectedBackendWithExplicit(allocator, io, "", envAdapter(env_map));
}

pub fn selectedBackendWithExplicit(
    allocator: std.mem.Allocator,
    io: std.Io,
    explicit_backend_or_adapter: []const u8,
    env_adapter: ?[]const u8,
) !?Selection {
    if (explicit_backend_or_adapter.len != 0) {
        return try selectionFromSetting(allocator, io, explicit_backend_or_adapter, "explicit");
    }

    if (try readConfiguredBackend(allocator, io)) |setting| {
        defer allocator.free(setting);
        return try selectionFromSetting(allocator, io, setting, adapter_config_file);
    }

    if (env_adapter) |setting| {
        if (setting.len != 0) {
            return try selectionFromSetting(allocator, io, setting, env_adapter_name);        }
    }

    return null;
}

pub fn selectionFromSetting(
    allocator: std.mem.Allocator,
    io: std.Io,
    setting: []const u8,
    source: []const u8,
) !Selection {
    const trimmed = trimConfig(setting);
    if (trimmed.len == 0) return error.MissingBackendAdapter;
    const active_backend = backendFromSetting(trimmed);
    return .{
        .backend = active_backend,
        .setting = try allocator.dupe(u8, trimmed),
        .source = source,
        .adapter_executable = try resolveAdapter(allocator, io, trimmed),
    };
}

pub fn backendFromSetting(setting: []const u8) Backend {
    return Backend.parse(setting) orelse .adapter;
}

pub fn readConfiguredBackend(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, adapter_config_file, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const trimmed = trimConfig(bytes);
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn writeConfiguredBackend(allocator: std.mem.Allocator, io: std.Io, setting: []const u8) !void {
    const bytes = try std.fmt.allocPrint(allocator, "{s}\n", .{setting});
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = adapter_config_file, .data = bytes });
}

pub fn validateBackendSetting(setting: []const u8) !void {
    if (setting.len == 0) return error.InvalidBackend;
    if (std.mem.indexOfAny(u8, setting, "\r\n") != null) return error.InvalidBackend;
}

pub fn trimConfig(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

pub fn resolveAdapter(allocator: std.mem.Allocator, io: std.Io, setting: []const u8) ![]u8 {
    if (builtinAdapter(setting)) |adapter| {
        if (try siblingAdapterPath(allocator, io, adapter.executable)) |path| {
            return path;
        }
        if (try cwdAdapterPath(allocator, io, &.{ "zig-out", "bin", adapter.executable })) |path| {
            return path;
        }
        if (try cwdAdapterPath(allocator, io, &.{adapter.executable})) |path| {
            return path;
        }
        return allocator.dupe(u8, adapter.executable);
    }

    return allocator.dupe(u8, setting);
}

pub fn builtinAdapter(name: []const u8) ?BuiltinAdapter {
    for (builtin_adapters) |adapter| {
        if (std.mem.eql(u8, adapter.name, name)) return adapter;
    }
    return null;
}

pub fn envAdapter(env_map: ?*std.process.Environ.Map) ?[]const u8 {
    const map = env_map orelse return null;
    return map.get(env_adapter_name);
}

fn cwdAdapterPath(allocator: std.mem.Allocator, io: std.Io, parts: []const []const u8) !?[]u8 {
    const path = try std.fs.path.join(allocator, parts);
    errdefer allocator.free(path);

    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => {
            allocator.free(path);
            return null;
        },
        else => return err,
    };

    return path;
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

test "parses backend names" {
    try std.testing.expectEqual(Backend.nix, Backend.parse("nix").?);
    try std.testing.expectEqual(Backend.guix, Backend.parse(" guix\n").?);
    try std.testing.expectEqual(Backend.adapter, Backend.parse("adapter").?);
    try std.testing.expect(Backend.parse("./custom-adapter") == null);
}

test "wraps adapter setting into backend selection" {
    var selection = try selectionFromSetting(std.testing.allocator, std.testing.io, "nix", "test");
    defer selection.deinit(std.testing.allocator);
    try std.testing.expectEqual(Backend.nix, selection.backend);
    try std.testing.expectEqualStrings("nix", selection.setting);

    var custom = try selectionFromSetting(std.testing.allocator, std.testing.io, "./fixtures/adapters/static-plan", "test");
    defer custom.deinit(std.testing.allocator);
    try std.testing.expectEqual(Backend.adapter, custom.backend);
    try std.testing.expectEqualStrings("adapter", custom.backendName());
    try std.testing.expectEqualStrings("./fixtures/adapters/static-plan", custom.adapter_executable);
}

test "recognizes built-in adapter names" {
    try std.testing.expect(builtinAdapter("nix") != null);
    try std.testing.expect(builtinAdapter("guix") != null);
    try std.testing.expect(builtinAdapter("custom") == null);
}

test "trims backend config" {
    try std.testing.expectEqualStrings("nix", trimConfig(" \tnix\r\n"));
}
