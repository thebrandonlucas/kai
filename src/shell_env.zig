const std = @import("std");
const backend_mod = @import("backend.zig");

pub const PreparedShell = struct {
    target: []const u8,
    generated_path: ?[]const u8,
    wrote: bool,
};

pub const shell_workspace_dir = ".kai/shell";
pub const nix_flake_path = shell_workspace_dir ++ "/flake.nix";
pub const guix_manifest_path = shell_workspace_dir ++ "/manifest.scm";

pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: backend_mod.Backend,
    name: []const u8,
    packages: []const []const u8,
) !PreparedShell {
    try validateShellName(name);
    try validatePackages(packages);
    try std.Io.Dir.cwd().createDirPath(io, shell_workspace_dir);

    return switch (backend) {
        .nix => blk: {
            const flake = try renderNixFlake(allocator, name, packages);
            defer allocator.free(flake);
            const wrote = try writeIfChanged(allocator, io, nix_flake_path, flake);
            break :blk .{ .target = "path:" ++ shell_workspace_dir, .generated_path = nix_flake_path, .wrote = wrote };
        },
        .guix => blk: {
            const manifest = try renderGuixManifest(allocator, packages);
            defer allocator.free(manifest);
            const wrote = try writeIfChanged(allocator, io, guix_manifest_path, manifest);
            break :blk .{ .target = shell_workspace_dir, .generated_path = guix_manifest_path, .wrote = wrote };
        },
        .adapter => .{ .target = shell_workspace_dir, .generated_path = null, .wrote = false },
    };
}

pub fn renderNixFlake(allocator: std.mem.Allocator, name: []const u8, packages: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const package_block = try renderNixPackageBlock(allocator, packages, 14, 12);
    defer allocator.free(package_block);

    try appendFmt(&out,
        \\{{
        \\  description = "Kai dev shell for {s}";
        \\
        \\  inputs = {{
        \\    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        \\  }};
        \\
        \\  outputs = {{ nixpkgs, ... }}:
        \\    let
        \\      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
        \\      forAllSystems = nixpkgs.lib.genAttrs systems;
        \\    in {{
        \\      devShells = forAllSystems (system:
        \\        let
        \\          pkgs = import nixpkgs {{ inherit system; }};
        \\        in {{
        \\          default = pkgs.mkShell {{
        \\            name = "{s}";
        \\            packages = [{s}];
        \\          }};
        \\        }});
        \\    }};
        \\}}
        \\
    , .{ name, sanitizedShellName(name), package_block });

    return out.toOwnedSlice();
}

pub fn renderGuixManifest(allocator: std.mem.Allocator, packages: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("(specifications->manifest\n  (list");
    for (packages) |package| {
        const quoted = try schemeString(allocator, package);
        defer allocator.free(quoted);
        try appendFmt(&out, "\n    {s}", .{quoted});
    }
    try out.appendSlice("))\n");
    return out.toOwnedSlice();
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

fn validatePackages(packages: []const []const u8) !void {
    for (packages) |package| {
        if (package.len == 0) return error.InvalidShellPackage;
        for (package) |ch| {
            switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '+' => {},
                else => return error.InvalidShellPackage,
            }
        }
    }
}

fn renderNixPackageBlock(allocator: std.mem.Allocator, packages: []const []const u8, indent: usize, closing_indent: usize) ![]u8 {
    if (packages.len == 0) return allocator.dupe(u8, " ");

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('\n');
    for (packages) |package| {
        try appendSpaces(&out, indent);
        try appendFmt(&out, "pkgs.{s}\n", .{package});
    }
    try appendSpaces(&out, closing_indent);
    return out.toOwnedSlice();
}

fn sanitizedShellName(name: []const u8) []const u8 {
    return if (name.len == 0) "kai-shell" else name;
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

fn schemeString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.append('"');
    for (value) |ch| {
        if (ch == '\\') {
            try out.appendSlice("\\\\");
        } else if (ch == '"') {
            try out.appendSlice("\\\"");
        } else {
            try out.append(ch);
        }
    }
    try out.append('"');
    return out.toOwnedSlice();
}

fn appendFmt(out: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(out.allocator, fmt, args);
    defer out.allocator.free(text);
    try out.appendSlice(text);
}

fn appendSpaces(out: *std.array_list.Managed(u8), count: usize) !void {
    try out.appendNTimes(' ', count);
}

test "uses shell subdirectory paths" {
    try std.testing.expectEqualStrings(".kai/shell", shell_workspace_dir);
    try std.testing.expectEqualStrings(".kai/shell/flake.nix", nix_flake_path);
    try std.testing.expectEqualStrings(".kai/shell/manifest.scm", guix_manifest_path);
}

test "renders nix shell flake" {
    const flake = try renderNixFlake(std.testing.allocator, "demo", &.{ "zig", "python3Packages.numpy" });
    defer std.testing.allocator.free(flake);
    try std.testing.expect(std.mem.indexOf(u8, flake, "devShells") != null);
    try std.testing.expect(std.mem.indexOf(u8, flake, "description = \"Kai dev shell for demo\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, flake, "name = \"demo\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, flake, "pkgs.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, flake, "pkgs.python3Packages.numpy") != null);
}

test "renders guix manifest" {
    const manifest = try renderGuixManifest(std.testing.allocator, &.{ "zig", "bash-minimal" });
    defer std.testing.allocator.free(manifest);
    try std.testing.expectEqualStrings("(specifications->manifest\n  (list\n    \"zig\"\n    \"bash-minimal\"))\n", manifest);
}

test "rejects invalid package names" {
    try std.testing.expectError(error.InvalidShellPackage, prepare(std.testing.allocator, std.testing.io, .nix, "demo", &.{"bad;pkg"}));
}
