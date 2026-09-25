//! Builds the roc-blueprint platform host into targets/<target>/libhost.a.
//!
//! The musl runtime files beside libhost.a (crt1.o, libc.a, libzigc.a,
//! libcompiler_rt.a) are not built here; they are vendored, see
//! targets/README.md.
const std = @import("std");

const Target = struct {
    dir: []const u8,
    query: std.Target.Query,
    /// Linux links the vendored musl runtime's compiler-rt; macOS has none.
    bundle_compiler_rt: bool,
};

const targets = [_]Target{
    .{ .dir = "x64musl", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .bundle_compiler_rt = false },
    .{ .dir = "arm64mac", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .bundle_compiler_rt = true },
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
        lib.bundle_compiler_rt = t.bundle_compiler_rt;
        copy.addCopyFileToSource(lib.getEmittedBin(), b.pathJoin(&.{ "targets", t.dir, "libhost.a" }));
    }
}
