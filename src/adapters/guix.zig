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
    const uses_manifest = has_target and std.mem.endsWith(u8, request.value.target, ".scm");
    const target_arg_count: usize = if (uses_manifest) 2 else if (has_target) 1 else 0;
    const plan_argv = try allocator.alloc([]const u8, 3 + target_arg_count + request.value.argv.len);

    var index: usize = 0;
    plan_argv[index] = "guix";
    index += 1;
    plan_argv[index] = "shell";
    index += 1;
    if (uses_manifest) {
        plan_argv[index] = "-m";
        index += 1;
        plan_argv[index] = request.value.target;
        index += 1;
    } else if (has_target) {
        plan_argv[index] = request.value.target;
        index += 1;
    }
    plan_argv[index] = "--";
    index += 1;
    for (request.value.argv) |arg| {
        plan_argv[index] = arg;
        index += 1;
    }

    try common.writePlanAlloc(allocator, init.io, .{ .protocol = common.protocol, .argv = plan_argv });
}
