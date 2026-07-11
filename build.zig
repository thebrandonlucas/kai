const std = @import("std");

const RocTarget = enum {
    x64mac,
    x64win,
    x64musl,
    arm64mac,
    arm64win,
    arm64musl,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64win => .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc },
            .x64musl => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .arm64win => .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .msvc },
            .arm64musl => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        };
    }

    fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .x64win => "x64win",
            .x64musl => "x64musl",
            .arm64mac => "arm64mac",
            .arm64win => "arm64win",
            .arm64musl => "arm64musl",
        };
    }

    fn libFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win, .arm64win => "host.lib",
            else => "libhost.a",
        };
    }
};

const all_targets = [_]RocTarget{
    .x64mac,
    .x64win,
    .x64musl,
    .arm64mac,
    .arm64win,
    .arm64musl,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.standardTargetOptions(.{});

    const cleanup_step = b.step("clean", "Remove generated host libraries");
    for (all_targets) |roc_target| {
        cleanup_step.dependOn(&CleanupStep.create(b, b.path(
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        )).step);
    }

    const native_step = b.step("native", "Build the native Roc host library");
    native_step.dependOn(cleanup_step);

    const native_roc_target = detectNativeRocTarget(native_target.result) orelse {
        std.debug.print("Unsupported native platform\n", .{});
        return;
    };

    const native_lib = buildHostLib(b, b.resolveTargetQuery(native_roc_target.toZigTarget()), optimize);
    b.installArtifact(native_lib);

    const nix_adapter = buildAdapter(b, "kai-adapter-nix", "src/adapters/nix.zig", native_target, optimize);
    const guix_adapter = buildAdapter(b, "kai-adapter-guix", "src/adapters/guix.zig", native_target, optimize);
    b.installArtifact(nix_adapter);
    b.installArtifact(guix_adapter);

    const copy_native = b.addUpdateSourceFiles();
    copy_native.addCopyFileToSource(
        native_lib.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), native_roc_target.libFilename() }),
    );
    native_step.dependOn(&native_lib.step);
    native_step.dependOn(&copy_native.step);

    const install_step = b.getInstallStep();
    install_step.dependOn(native_step);

    const test_step = b.step("test", "Run Zig unit tests");

    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const run_host_tests = b.addRunArtifact(host_tests);
    test_step.dependOn(&run_host_tests.step);

    const e2e_step = b.step("e2e", "Run real nix/guix subprocess examples");
    const run_nix_example = b.addSystemCommand(&.{ "roc", "examples/shell.roc" });
    run_nix_example.step.dependOn(install_step);
    run_nix_example.step.dependOn(&run_host_tests.step);
    e2e_step.dependOn(&run_nix_example.step);

    const run_guix_example = b.addSystemCommand(&.{ "roc", "examples/shell-guix.roc" });
    run_guix_example.step.dependOn(install_step);
    run_guix_example.step.dependOn(&run_host_tests.step);
    e2e_step.dependOn(&run_guix_example.step);
}

fn detectNativeRocTarget(target: std.Target) ?RocTarget {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .x86_64 => .x64mac,
            .aarch64 => .arm64mac,
            else => null,
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => .x64musl,
            .aarch64 => .arm64musl,
            else => null,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => .x64win,
            .aarch64 => .arm64win,
            else => null,
        },
        else => null,
    };
}

const CleanupStep = struct {
    step: std.Build.Step,
    path: std.Build.LazyPath,

    fn create(b: *std.Build, path: std.Build.LazyPath) *CleanupStep {
        const self = b.allocator.create(CleanupStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "cleanup",
                .owner = b,
                .makeFn = make,
            }),
            .path = path,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CleanupStep = @fieldParentPtr("step", step);
        const path = self.path.getPath2(step.owner, null);
        std.Io.Dir.cwd().deleteFile(step.owner.graph.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

fn buildAdapter(
    b: *std.Build,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });
}

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
        }),
    });
    host_lib.bundle_compiler_rt = true;
    return host_lib;
}
