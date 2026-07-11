const std = @import("std");

pub const protocol = "kai.adapter.v0";

pub const Request = struct {
    protocol: []const u8,
    command: []const u8,
    target: []const u8,
    argv: []const []const u8,
};

pub const Plan = struct {
    protocol: []const u8,
    argv: []const []const u8,
};

pub fn readRequest(allocator: std.mem.Allocator, args: []const [:0]const u8) !std.json.Parsed(Request) {
    if (args.len != 2) {
        return error.InvalidAdapterArgs;
    }

    var parsed = try std.json.parseFromSlice(Request, allocator, args[1], .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.protocol, protocol)) {
        return error.UnsupportedAdapterProtocol;
    }
    if (!std.mem.eql(u8, parsed.value.command, "shell")) {
        return error.UnsupportedProtocolCommand;
    }
    if (parsed.value.argv.len == 0) {
        return error.EmptyShellCommand;
    }

    return parsed;
}

pub fn writePlanAlloc(allocator: std.mem.Allocator, io: std.Io, plan: Plan) !void {
    const json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(plan, .{})});
    defer allocator.free(json);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, json);
    try stdout.writeStreamingAll(io, "\n");
}
