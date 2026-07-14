const std = @import("std");

pub const PreparedShell = struct {
    target: []const u8,
    target_is_owned: bool = false,
    generated_path: ?[]const u8,
    wrote: bool,

    pub fn deinit(self: PreparedShell, allocator: std.mem.Allocator) void {
        if (self.target_is_owned) allocator.free(self.target);
    }
};

pub const shell_workspace_dir = ".kai/shell";
pub const nix_flake_path = shell_workspace_dir ++ "/flake.nix";

pub fn prepareNixSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_name: []const u8,
    source: []const u8,
) !PreparedShell {
    try validateShellName(env_name);
    try std.Io.Dir.cwd().createDirPath(io, shell_workspace_dir);
    const wrote = try writeIfChanged(allocator, io, nix_flake_path, source);
    const target = try std.fmt.allocPrint(allocator, "path:" ++ shell_workspace_dir ++ "#{s}", .{env_name});
    return .{ .target = target, .target_is_owned = true, .generated_path = nix_flake_path, .wrote = wrote };
}

fn validateShellName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidShellName;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '+' => {},
            else => return error.InvalidShellName,
        }
    }
}

fn writeIfChanged(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !bool {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
            return true;
        },
        else => return err,
    };
    defer allocator.free(existing);

    if (std.mem.eql(u8, existing, content)) return false;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
    return true;
}

test "uses shell subdirectory paths" {
    try std.testing.expectEqualStrings(".kai/shell", shell_workspace_dir);
    try std.testing.expectEqualStrings(".kai/shell/flake.nix", nix_flake_path);
}

test "prepares typed nix shell source" {
    const source = "{ outputs = { ... }: { }; }\n";
    const prepared = try prepareNixSource(std.testing.allocator, std.testing.io, "default", source);
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("path:.kai/shell#default", prepared.target);
    try std.testing.expectEqualStrings(nix_flake_path, prepared.generated_path.?);
}

test "rejects invalid shell env names" {
    try std.testing.expectError(error.InvalidShellName, prepareNixSource(std.testing.allocator, std.testing.io, "bad;env", ""));
}
