//! Builds the Kai platform host into targets/<target>/libhost.a, beside the
//! musl runtime files it links with (crt1.o, libc.a, libzigc.a,
//! libcompiler_rt.a), copied from the link_inputs dependency, see
//! targets/README.md.
const std = @import("std");

const Target = struct {
    dir: []const u8,
    query: std.Target.Query,
};

const targets = [_]Target{
    .{ .dir = "x64musl", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .dir = "arm64musl", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .dir = "arm64mac", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
};

const runtime_files = [_][]const u8{ "crt1.o", "libc.a", "libzigc.a", "libcompiler_rt.a" };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const link_inputs = b.dependency("link_inputs", .{});
    const copy = b.addUpdateSourceFiles();
    b.getInstallStep().dependOn(&copy.step);

    for (targets) |t| {
        const lib = b.addLibrary(.{
            .name = "host",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("host/host.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = optimize,
                .strip = optimize != .Debug,
                .pic = true,
            }),
        });
        // The fetched musl runtime supplies compiler-rt; macOS has none.
        lib.bundle_compiler_rt = t.query.os_tag == .macos;
        copy.addCopyFileToSource(lib.getEmittedBin(), b.pathJoin(&.{ "targets", t.dir, "libhost.a" }));
        if (t.query.abi == .musl) {
            for (runtime_files) |file| {
                const path = b.pathJoin(&.{ "targets", t.dir, file });
                copy.addCopyFileToSource(link_inputs.path(path), path);
            }
        }
    }
}
