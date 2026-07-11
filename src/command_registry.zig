const std = @import("std");
const backend_mod = @import("backend.zig");

pub const Backend = backend_mod.Backend;

pub const ProtocolShape = enum {
    shell_v1,
    machine_build_v1,
};

pub const Handler = enum {
    roc_config_section,
    shell_adapter,
    machine_nix_build,
    fake,
};

pub const ProtocolCommand = struct {
    name: []const u8,
    shape: ProtocolShape,
    aliases: []const []const u8 = &.{},
};

pub const CommandImplementation = struct {
    id: []const u8,
    command_name: []const u8,
    backend: Backend,
    handler: Handler,
    is_default: bool = false,
};

pub const ExtraCommand = struct {
    name: []const u8,
    handler: Handler,
};

pub const ImplementationSelection = union(enum) {
    ok: *const CommandImplementation,
    command_not_registered,
    backend_unsupported,
    implementation_not_found,
    implementation_backend_mismatch: *const CommandImplementation,
};

pub const ProtocolRegistry = struct {
    commands: []const ProtocolCommand,
    implementations: []const CommandImplementation,

    pub fn lookup(self: ProtocolRegistry, name_or_alias: []const u8) ?*const ProtocolCommand {
        for (self.commands) |*command| {
            if (std.mem.eql(u8, command.name, name_or_alias)) return command;
            for (command.aliases) |alias| {
                if (std.mem.eql(u8, alias, name_or_alias)) return command;
            }
        }
        return null;
    }

    pub fn selectImplementation(
        self: ProtocolRegistry,
        command_name: []const u8,
        active_backend: Backend,
        override_id: ?[]const u8,
    ) ImplementationSelection {
        const command = self.lookup(command_name) orelse return .command_not_registered;

        if (override_id) |id| {
            for (self.implementations) |*implementation| {
                if (std.mem.eql(u8, implementation.id, id) and std.mem.eql(u8, implementation.command_name, command.name)) {
                    if (implementation.backend != active_backend) {
                        return .{ .implementation_backend_mismatch = implementation };
                    }
                    return .{ .ok = implementation };
                }
            }
            return .implementation_not_found;
        }

        var saw_command_implementation = false;
        for (self.implementations) |*implementation| {
            if (!std.mem.eql(u8, implementation.command_name, command.name)) continue;
            saw_command_implementation = true;
            if (implementation.backend == active_backend and implementation.is_default) {
                return .{ .ok = implementation };
            }
        }

        return if (saw_command_implementation) .backend_unsupported else .implementation_not_found;
    }
};

pub const ExtraRegistry = struct {
    commands: []const ExtraCommand,

    pub fn lookup(self: ExtraRegistry, name: []const u8) ?*const ExtraCommand {
        for (self.commands) |*command| {
            if (std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
    }
};

const build_aliases = [_][]const u8{"build"};

pub const default_protocol_commands = [_]ProtocolCommand{
    .{ .name = "shell", .shape = .shell_v1 },
    .{ .name = "machine.build", .shape = .machine_build_v1, .aliases = &build_aliases },
};

pub const default_command_implementations = [_]CommandImplementation{
    .{ .id = "shell.default.nix", .command_name = "shell", .backend = .nix, .handler = .roc_config_section, .is_default = true },
    .{ .id = "shell.default.guix", .command_name = "shell", .backend = .guix, .handler = .roc_config_section, .is_default = true },
    .{ .id = "shell.default.adapter", .command_name = "shell", .backend = .adapter, .handler = .roc_config_section, .is_default = true },
    .{ .id = "machine.build.default.nix", .command_name = "machine.build", .backend = .nix, .handler = .roc_config_section, .is_default = true },
};

pub const default_protocol_registry = ProtocolRegistry{
    .commands = &default_protocol_commands,
    .implementations = &default_command_implementations,
};

pub const default_extra_commands = [_]ExtraCommand{};
pub const default_extra_registry = ExtraRegistry{ .commands = &default_extra_commands };

pub fn cliImplementationOverrideName(allocator: std.mem.Allocator, command_name: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, "KAI_IMPLEMENTATION_".len + command_name.len);
    @memcpy(out[0.."KAI_IMPLEMENTATION_".len], "KAI_IMPLEMENTATION_");
    for (command_name, 0..) |ch, i| {
        out["KAI_IMPLEMENTATION_".len + i] = switch (ch) {
            'a'...'z' => ch - 32,
            'A'...'Z', '0'...'9' => ch,
            else => '_',
        };
    }
    return out;
}

test "looks up protocol commands and aliases" {
    const registry = default_protocol_registry;
    try std.testing.expect(registry.lookup("shell") != null);
    const build = registry.lookup("build").?;
    try std.testing.expectEqualStrings("machine.build", build.name);
    try std.testing.expect(registry.lookup("deploy") == null);
}

test "keeps extra commands separate from protocol registry" {
    const extra = [_]ExtraCommand{.{ .name = "deploy", .handler = .fake }};
    const extra_registry = ExtraRegistry{ .commands = &extra };
    try std.testing.expect(default_protocol_registry.lookup("deploy") == null);
    try std.testing.expect(extra_registry.lookup("deploy") != null);
}

test "selects default implementation for active backend" {
    const selected = default_protocol_registry.selectImplementation("shell", .nix, null);
    switch (selected) {
        .ok => |implementation| try std.testing.expectEqualStrings("shell.default.nix", implementation.id),
        else => return error.TestExpectedDefaultImplementation,
    }
}

test "selects alternate implementation when requested" {
    const commands = [_]ProtocolCommand{.{ .name = "shell", .shape = .shell_v1 }};
    const implementations = [_]CommandImplementation{
        .{ .id = "shell.default.nix", .command_name = "shell", .backend = .nix, .handler = .fake, .is_default = true },
        .{ .id = "shell.tvix.nix", .command_name = "shell", .backend = .nix, .handler = .fake, .is_default = false },
    };
    const registry = ProtocolRegistry{ .commands = &commands, .implementations = &implementations };
    const selected = registry.selectImplementation("shell", .nix, "shell.tvix.nix");
    switch (selected) {
        .ok => |implementation| try std.testing.expectEqualStrings("shell.tvix.nix", implementation.id),
        else => return error.TestExpectedAlternateImplementation,
    }
}

test "reports unsupported backend for machine build on guix" {
    const selected = default_protocol_registry.selectImplementation("machine.build", .guix, null);
    try std.testing.expectEqual(ImplementationSelection.backend_unsupported, selected);
}

test "reports unregistered command" {
    const selected = default_protocol_registry.selectImplementation("deploy", .nix, null);
    try std.testing.expectEqual(ImplementationSelection.command_not_registered, selected);
}

test "reports implementation backend mismatch" {
    const selected = default_protocol_registry.selectImplementation("shell", .guix, "shell.default.nix");
    switch (selected) {
        .implementation_backend_mismatch => |implementation| try std.testing.expectEqualStrings("shell.default.nix", implementation.id),
        else => return error.TestExpectedBackendMismatch,
    }
}

test "builds implementation override env var name" {
    const name = try cliImplementationOverrideName(std.testing.allocator, "machine.build");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("KAI_IMPLEMENTATION_MACHINE_BUILD", name);
}
