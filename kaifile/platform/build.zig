//! Builds the Kaifile platform host into targets/<target>/libhost.a.
//!
//! The musl runtime files beside libhost.a (crt1.o, libc.a, libzigc.a,
//! libcompiler_rt.a) are not built here; they are vendored, see
//! targets/README.md.
const std = @import("std");

const Target = struct {
    dir: []const u8,
    query: std.Target.Query,
};

const targets = [_]Target{
    .{ .dir = "x64musl", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
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
        // The vendored musl runtime supplies compiler-rt.
        lib.bundle_compiler_rt = false;
        copy.addCopyFileToSource(lib.getEmittedBin(), b.pathJoin(&.{ "targets", t.dir, "libhost.a" }));
    }
}
