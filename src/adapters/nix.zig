const std = @import("std");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    var request = try common.readRequest(allocator, args);
    defer request.deinit();

    const has_target = request.value.target.len != 0;
    const target_arg_count: usize = if (has_target) 1 else 0;
    const plan_argv = try allocator.alloc([]const u8, 4 + target_arg_count + request.value.argv.len);

    var index: usize = 0;
    plan_argv[index] = "nix";
    index += 1;
    plan_argv[index] = "develop";
    index += 1;
    plan_argv[index] = "--no-write-lock-file";
    index += 1;
    if (has_target) {
        plan_argv[index] = request.value.target;
        index += 1;
    }
    plan_argv[index] = "--command";
    index += 1;
    for (request.value.argv) |arg| {
        plan_argv[index] = arg;
        index += 1;
    }

    try common.writePlanAlloc(allocator, init.io, .{ .protocol = common.protocol, .argv = plan_argv });
}
