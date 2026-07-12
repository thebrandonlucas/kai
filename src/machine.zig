const std = @import("std");
const builtin = @import("builtin");
const spinner_mod = @import("spinner.zig");

pub const ImageFormat = enum {
    raw,
    qcow2,

    pub fn parse(value: []const u8) ?ImageFormat {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "raw")) return .raw;
        if (std.mem.eql(u8, trimmed, "qcow") or std.mem.eql(u8, trimmed, "qcow2")) return .qcow2;
        return null;
    }

    pub fn nixosGeneratorsFormat(self: ImageFormat) []const u8 {
        return switch (self) {
            .raw => "raw",
            .qcow2 => "qcow",
        };
    }
};

pub const BuildSpec = struct {
    hostname: []const u8,
    system: []const u8,
    packages: []const []const u8,
    ssh_keys: []const []const u8,
    state_version: []const u8,
    image_format: ImageFormat,
};

pub const machine_workspace_dir = ".kai/machine";
pub const machine_flake_path = machine_workspace_dir ++ "/flake.nix";

pub fn build(allocator: std.mem.Allocator, io: std.Io, spec: BuildSpec) !u8 {
    try std.Io.Dir.cwd().createDirPath(io, machine_workspace_dir);

    const flake = try renderFlake(allocator, spec);
    defer allocator.free(flake);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = machine_flake_path, .data = flake });

    const attr = try imagePackageAttr(allocator, spec);
    defer allocator.free(attr);
    const output = try imagePackageOutputFromAttr(allocator, attr);
    defer allocator.free(output);

    const argv = nixBuildArgv(output);
    try writeFmt(allocator, io, .stdout, "wrote {s}\nmachine output: {s}\nrunning nix build {s}\n", .{ machine_flake_path, attr, output });

    return runArgvStatusQuietWithSpinner(allocator, io, &argv, "nix build");
}

pub fn imagePackageAttr(allocator: std.mem.Allocator, spec: BuildSpec) ![]u8 {
    return std.fmt.allocPrint(allocator, "packages.{s}.{s}-image", .{ spec.system, spec.hostname });
}

pub fn imagePackageOutput(allocator: std.mem.Allocator, spec: BuildSpec) ![]u8 {
    const attr = try imagePackageAttr(allocator, spec);
    defer allocator.free(attr);
    return imagePackageOutputFromAttr(allocator, attr);
}

fn imagePackageOutputFromAttr(allocator: std.mem.Allocator, attr: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "path:" ++ machine_workspace_dir ++ "#{s}", .{attr});
}

pub fn nixBuildArgv(output: []const u8) [3][]const u8 {
    return .{ "nix", "build", output };
}

pub fn renderFlake(allocator: std.mem.Allocator, spec: BuildSpec) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const hostname = try nixString(allocator, spec.hostname);
    defer allocator.free(hostname);
    const system = try nixString(allocator, spec.system);
    defer allocator.free(system);
    const state_version = try nixString(allocator, spec.state_version);
    defer allocator.free(state_version);
    const format = try nixString(allocator, spec.image_format.nixosGeneratorsFormat());
    defer allocator.free(format);
    const package_block = try renderPackageBlock(allocator, spec.packages, 10, 8);
    defer allocator.free(package_block);
    const ssh_key_block = try renderSshKeyBlock(allocator, spec.ssh_keys);
    defer allocator.free(ssh_key_block);

    try appendFmt(&out,
        \\{{
        \\  description = "Kai machine image";
        \\
        \\  inputs = {{
        \\    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        \\    nixos-generators.url = "github:nix-community/nixos-generators";
        \\    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
        \\  }};
        \\
        \\  outputs = {{ nixpkgs, nixos-generators, ... }}:
        \\    let
        \\      kaiMachineModule =
        \\        {{ lib, modulesPath, pkgs, ... }}: {{
        \\        imports = [
        \\          (modulesPath + "/profiles/qemu-guest.nix")
        \\        ];
        \\
        \\        networking.hostName = {s};
        \\        networking.useDHCP = lib.mkDefault true;
        \\
        \\        services.openssh.enable = true;
        \\        services.openssh.settings.PasswordAuthentication = false;
        \\        services.openssh.settings.PermitRootLogin = "prohibit-password";
        \\        users.users.root.openssh.authorizedKeys.keys = [{s}];
        \\
        \\        environment.systemPackages = [{s}];
        \\
        \\        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        \\        system.stateVersion = {s};
        \\      }};
        \\    in {{
        \\      nixosConfigurations.{s} = nixpkgs.lib.nixosSystem {{
        \\        system = {s};
        \\        modules = [ kaiMachineModule ];
        \\      }};
        \\
        \\      packages.{s}.{s}-image = nixos-generators.nixosGenerate {{
        \\        system = {s};
        \\        modules = [ kaiMachineModule ];
        \\        format = {s};
        \\      }};
        \\    }};
        \\}}
        \\
    , .{
        hostname,
        ssh_key_block,
        package_block,
        state_version,
        spec.hostname,
        system,
        spec.system,
        spec.hostname,
        system,
        format,
    });

    return out.toOwnedSlice();
}

fn renderPackageBlock(allocator: std.mem.Allocator, packages: []const []const u8, indent: usize, closing_indent: usize) ![]const u8 {
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

fn renderSshKeyBlock(allocator: std.mem.Allocator, keys: []const []const u8) ![]const u8 {
    if (keys.len == 0) return allocator.dupe(u8, " ");

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('\n');
    for (keys) |key| {
        const quoted = try nixString(allocator, key);
        defer allocator.free(quoted);
        try appendFmt(&out, "          {s}\n", .{quoted});
    }
    try out.appendSlice("        ");
    return out.toOwnedSlice();
}

fn nixString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.append('"');
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const ch = value[index];
        if (ch == '\\') {
            try out.appendSlice("\\\\");
        } else if (ch == '"') {
            try out.appendSlice("\\\"");
        } else if (ch == '$' and index + 1 < value.len and value[index + 1] == '{') {
            try out.appendSlice("\\$");
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

const Stream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    try file.writeStreamingAll(io, bytes);
}

fn writeFmt(allocator: std.mem.Allocator, io: std.Io, stream: Stream, comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try writeAll(io, stream, bytes);
}

fn runArgvStatus(io: std.Io, argv: []const []const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .expand_arg0 = .expand,
    });
    errdefer child.kill(io);

    return exitCode(try child.wait(io));
}

fn runArgvStatusQuietWithSpinner(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, description: []const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .ignore,
        .stderr = .ignore,
        .expand_arg0 = .expand,
    });
    errdefer child.kill(io);

    const message = try std.fmt.allocPrint(allocator, "{s}…", .{description});
    defer allocator.free(message);
    var spinner = try spinner_mod.Spinner.start(allocator, io, message, .animal);
    defer spinner.deinit();

    while (true) {
        if (try pollChildExit(&child)) |term| {
            spinner.stop();
            return exitCode(term);
        }
        io.sleep(.fromMilliseconds(120), .awake) catch {};
        spinner.tick();
    }
}

fn pollChildExit(child: *std.process.Child) !?std.process.Child.Term {
    return switch (builtin.os.tag) {
        .linux => pollLinuxChildExit(child),
        else => null,
    };
}

fn pollLinuxChildExit(child: *std.process.Child) !?std.process.Child.Term {
    const pid = child.id orelse return null;
    var status: u32 = 0;
    const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => blk: {
            if (rc == 0) break :blk null;
            child.id = null;
            break :blk linuxStatusToTerm(status);
        },
        .INTR => null,
        else => error.UnexpectedWaitPidError,
    };
}

fn linuxStatusToTerm(status: u32) std.process.Child.Term {
    if (std.os.linux.W.IFEXITED(status)) {
        return .{ .exited = std.os.linux.W.EXITSTATUS(status) };
    }
    if (std.os.linux.W.IFSIGNALED(status)) {
        return .{ .signal = @enumFromInt(@intFromEnum(std.os.linux.W.TERMSIG(status))) };
    }
    if (std.os.linux.W.IFSTOPPED(status)) {
        return .{ .stopped = @enumFromInt(@intFromEnum(std.os.linux.W.STOPSIG(status))) };
    }
    return .{ .unknown = status };
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

test "parses image formats" {
    try std.testing.expectEqual(ImageFormat.raw, ImageFormat.parse("raw").?);
    try std.testing.expectEqual(ImageFormat.qcow2, ImageFormat.parse("qcow").?);
    try std.testing.expectEqual(ImageFormat.qcow2, ImageFormat.parse("qcow2").?);
    try std.testing.expect(ImageFormat.parse("vmdk") == null);
}

test "renders image package output under machine subflake" {
    const output = try imagePackageOutput(std.testing.allocator, .{
        .hostname = "web",
        .system = "x86_64-linux",
        .packages = &.{},
        .ssh_keys = &.{},
        .state_version = "25.05",
        .image_format = .qcow2,
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("path:.kai/machine#packages.x86_64-linux.web-image", output);
}

test "builds nix build argv" {
    const argv = nixBuildArgv("path:.kai/machine#packages.x86_64-linux.web-image");
    try std.testing.expectEqualStrings("nix", argv[0]);
    try std.testing.expectEqualStrings("build", argv[1]);
    try std.testing.expectEqualStrings("path:.kai/machine#packages.x86_64-linux.web-image", argv[2]);
}

test "run argv status returns child exit code" {
    const code = try runArgvStatus(std.testing.io, &.{ "sh", "-c", "exit 6" });
    try std.testing.expectEqual(@as(u8, 6), code);
}

test "renders machine flake" {
    const flake = try renderFlake(std.testing.allocator, .{
        .hostname = "web",
        .system = "x86_64-linux",
        .packages = &.{"git"},
        .ssh_keys = &.{"ssh-ed25519 AAAA test"},
        .state_version = "25.05",
        .image_format = .qcow2,
    });
    defer std.testing.allocator.free(flake);

    try std.testing.expect(std.mem.indexOf(u8, flake, "packages.x86_64-linux.web-image") != null);
    try std.testing.expect(std.mem.indexOf(u8, flake, "format = \"qcow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, flake, "pkgs.git") != null);
}
