const std = @import("std");

pub const blueprint_config_file = ".kai/blueprint";
pub const legacy_backend_config_file = ".kai/backend";
pub const legacy_adapter_config_file = ".kai/adapter";
pub const env_blueprint_name = "KAI_BLUEPRINT";
pub const legacy_env_adapter_name = "KAI_BACKEND_ADAPTER";

pub const Blueprint = enum {
    nix,
    guix,
    custom,

    pub fn name(self: Blueprint) []const u8 {
        return switch (self) {
            .nix => "nix",
            .guix => "guix",
            .custom => "custom",
        };
    }

    pub fn parse(value: []const u8) ?Blueprint {
        const trimmed = trimConfig(value);
        if (std.mem.eql(u8, trimmed, "nix")) return .nix;
        if (std.mem.eql(u8, trimmed, "guix")) return .guix;
        if (std.mem.eql(u8, trimmed, "custom")) return .custom;
        if (std.mem.eql(u8, trimmed, "adapter")) return .custom;
        return null;
    }
};

pub const BuiltinBlueprint = struct {
    blueprint: Blueprint,
    name: []const u8,
    executable: []const u8,
    legacy_executable: []const u8,
};

pub const builtin_blueprints = [_]BuiltinBlueprint{
    .{ .blueprint = .nix, .name = "nix", .executable = "kai-blueprint-nix", .legacy_executable = "kai-adapter-nix" },
    .{ .blueprint = .guix, .name = "guix", .executable = "kai-blueprint-guix", .legacy_executable = "kai-adapter-guix" },
};

const ConfiguredBlueprint = struct {
    setting: []u8,
    source: []const u8,

    fn deinit(self: ConfiguredBlueprint, allocator: std.mem.Allocator) void {
        allocator.free(self.setting);
    }
};

const EnvBlueprint = struct {
    setting: []const u8,
    source: []const u8,
};

pub const Selection = struct {
    blueprint: Blueprint,
    setting: []u8,
    source: []const u8,
    blueprint_executable: []u8,

    pub fn deinit(self: Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.setting);
        allocator.free(self.blueprint_executable);
    }

    pub fn blueprintName(self: Selection) []const u8 {
        return self.blueprint.name();
    }
};

pub fn selectedBlueprint(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: ?*std.process.Environ.Map,
) !?Selection {
    const env = envBlueprintWithSource(env_map);
    return selectedBlueprintWithExplicit(allocator, io, "", if (env) |entry| entry.setting else null, if (env) |entry| entry.source else null);
}

pub fn selectedBlueprintWithExplicit(
    allocator: std.mem.Allocator,
    io: std.Io,
    explicit_blueprint_or_executable: []const u8,
    env_blueprint: ?[]const u8,
    env_source: ?[]const u8,
) !?Selection {
    if (explicit_blueprint_or_executable.len != 0) {
        return try selectionFromSetting(allocator, io, explicit_blueprint_or_executable, "explicit");
    }

    if (try readConfiguredBlueprintWithSource(allocator, io)) |configured| {
        defer configured.deinit(allocator);
        return try selectionFromSetting(allocator, io, configured.setting, configured.source);
    }

    if (env_blueprint) |setting| {
        if (setting.len != 0) {
            return try selectionFromSetting(allocator, io, setting, env_source orelse env_blueprint_name);
        }
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
    if (trimmed.len == 0) return error.MissingBlueprint;
    const active_blueprint = blueprintFromSetting(trimmed);
    return .{
        .blueprint = active_blueprint,
        .setting = try allocator.dupe(u8, trimmed),
        .source = source,
        .blueprint_executable = try resolveBlueprint(allocator, io, trimmed),
    };
}

pub fn blueprintFromSetting(setting: []const u8) Blueprint {
    return Blueprint.parse(setting) orelse .custom;
}

pub fn readConfiguredBlueprint(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try readConfiguredBlueprintWithSource(allocator, io)) |configured| {
        defer configured.deinit(allocator);
        return try allocator.dupe(u8, configured.setting);
    }
    return null;
}

fn readConfiguredBlueprintWithSource(allocator: std.mem.Allocator, io: std.Io) !?ConfiguredBlueprint {
    if (try readConfiguredBlueprintFile(allocator, io, blueprint_config_file)) |setting| {
        return .{ .setting = setting, .source = blueprint_config_file };
    }
    if (try readConfiguredBlueprintFile(allocator, io, legacy_backend_config_file)) |setting| {
        return .{ .setting = setting, .source = legacy_backend_config_file };
    }
    if (try readConfiguredBlueprintFile(allocator, io, legacy_adapter_config_file)) |setting| {
        return .{ .setting = setting, .source = legacy_adapter_config_file };
    }
    return null;
}

fn readConfiguredBlueprintFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const trimmed = trimConfig(bytes);
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn writeConfiguredBlueprint(allocator: std.mem.Allocator, io: std.Io, setting: []const u8) !void {
    const bytes = try std.fmt.allocPrint(allocator, "{s}\n", .{setting});
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().createDirPath(io, ".kai");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = blueprint_config_file, .data = bytes });
}

pub fn validateBlueprintSetting(setting: []const u8) !void {
    if (setting.len == 0) return error.InvalidBlueprint;
    if (std.mem.indexOfAny(u8, setting, "\r\n") != null) return error.InvalidBlueprint;
}

pub fn trimConfig(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

pub fn resolveBlueprint(allocator: std.mem.Allocator, io: std.Io, setting: []const u8) ![]u8 {
    if (builtinBlueprint(setting)) |blueprint| {
        if (try executablePath(allocator, io, blueprint.executable)) |path| return path;
        if (try executablePath(allocator, io, blueprint.legacy_executable)) |path| return path;
        return allocator.dupe(u8, blueprint.executable);
    }

    return allocator.dupe(u8, setting);
}

pub fn builtinBlueprint(name: []const u8) ?BuiltinBlueprint {
    for (builtin_blueprints) |blueprint| {
        if (std.mem.eql(u8, blueprint.name, name)) return blueprint;
    }
    return null;
}

pub fn envBlueprint(env_map: ?*std.process.Environ.Map) ?[]const u8 {
    return if (envBlueprintWithSource(env_map)) |entry| entry.setting else null;
}

fn envBlueprintWithSource(env_map: ?*std.process.Environ.Map) ?EnvBlueprint {
    const map = env_map orelse return null;
    if (map.get(env_blueprint_name)) |setting| {
        if (setting.len != 0) return .{ .setting = setting, .source = env_blueprint_name };
    }
    if (map.get(legacy_env_adapter_name)) |setting| {
        if (setting.len != 0) return .{ .setting = setting, .source = legacy_env_adapter_name };
    }
    return null;
}

fn executablePath(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) !?[]u8 {
    if (try siblingExecutablePath(allocator, io, executable)) |path| {
        return path;
    }
    if (try cwdExecutablePath(allocator, io, &.{ "zig-out", "bin", executable })) |path| {
        return path;
    }
    if (try cwdExecutablePath(allocator, io, &.{executable})) |path| {
        return path;
    }
    return null;
}

fn cwdExecutablePath(allocator: std.mem.Allocator, io: std.Io, parts: []const []const u8) !?[]u8 {
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

fn siblingExecutablePath(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) !?[]u8 {
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

test "parses blueprint names" {
    try std.testing.expectEqual(Blueprint.nix, Blueprint.parse("nix").?);
    try std.testing.expectEqual(Blueprint.guix, Blueprint.parse(" guix\n").?);
    try std.testing.expectEqual(Blueprint.custom, Blueprint.parse("custom").?);
    try std.testing.expectEqual(Blueprint.custom, Blueprint.parse("adapter").?);
    try std.testing.expect(Blueprint.parse("./custom-blueprint") == null);
}

test "wraps executable setting into blueprint selection" {
    var selection = try selectionFromSetting(std.testing.allocator, std.testing.io, "nix", "test");
    defer selection.deinit(std.testing.allocator);
    try std.testing.expectEqual(Blueprint.nix, selection.blueprint);
    try std.testing.expectEqualStrings("nix", selection.setting);

    var custom = try selectionFromSetting(std.testing.allocator, std.testing.io, "./fixtures/adapters/static-plan", "test");
    defer custom.deinit(std.testing.allocator);
    try std.testing.expectEqual(Blueprint.custom, custom.blueprint);
    try std.testing.expectEqualStrings("custom", custom.blueprintName());
    try std.testing.expectEqualStrings("./fixtures/adapters/static-plan", custom.blueprint_executable);
}

test "recognizes built-in blueprint names" {
    try std.testing.expect(builtinBlueprint("nix") != null);
    try std.testing.expect(builtinBlueprint("guix") != null);
    try std.testing.expect(builtinBlueprint("custom") == null);
}

test "uses .kai directory for blueprint config and keeps legacy paths" {
    try std.testing.expectEqualStrings(".kai/blueprint", blueprint_config_file);
    try std.testing.expectEqualStrings(".kai/backend", legacy_backend_config_file);
    try std.testing.expectEqualStrings(".kai/adapter", legacy_adapter_config_file);
}

test "trims blueprint config" {
    try std.testing.expectEqualStrings("nix", trimConfig(" \tnix\r\n"));
}
