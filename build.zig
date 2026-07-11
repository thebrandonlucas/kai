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

    const kai_cli = b.addExecutable(.{
        .name = "kai",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(kai_cli);

    const copy_native = b.addUpdateSourceFiles();
    copy_native.addCopyFileToSource(
        native_lib.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), native_roc_target.libFilename() }),
    );
    native_step.dependOn(&native_lib.step);
    native_step.dependOn(&copy_native.step);

    const roc_adapters_step = b.step("roc-adapters", "Build dependency-free Roc backend adapters");
    const make_bin_dir = b.addSystemCommand(&.{ "mkdir", "-p", b.getInstallPath(.bin, "") });
    make_bin_dir.step.dependOn(native_step);

    const build_nix_adapter = b.addSystemCommand(&.{
        "roc",
        "build",
        "adapters/roc/nix.roc",
        b.fmt("--output={s}", .{b.getInstallPath(.bin, "kai-adapter-nix")}),
    });
    build_nix_adapter.step.dependOn(&make_bin_dir.step);
    roc_adapters_step.dependOn(&build_nix_adapter.step);

    const build_guix_adapter = b.addSystemCommand(&.{
        "roc",
        "build",
        "adapters/roc/guix.roc",
        b.fmt("--output={s}", .{b.getInstallPath(.bin, "kai-adapter-guix")}),
    });
    build_guix_adapter.step.dependOn(&make_bin_dir.step);
    roc_adapters_step.dependOn(&build_guix_adapter.step);

    const install_step = b.getInstallStep();
    install_step.dependOn(native_step);
    install_step.dependOn(roc_adapters_step);

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

    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol_tests.step);

    const machine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/machine.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const run_machine_tests = b.addRunArtifact(machine_tests);
    test_step.dependOn(&run_machine_tests.step);

    const backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/backend.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const run_backend_tests = b.addRunArtifact(backend_tests);
    test_step.dependOn(&run_backend_tests.step);

    const command_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/command_registry.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const run_command_registry_tests = b.addRunArtifact(command_registry_tests);
    test_step.dependOn(&run_command_registry_tests.step);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);

    const e2e_step = b.step("e2e", "Run real nix/guix subprocess examples");
    const run_nix_example = b.addSystemCommand(&.{
        "env",
        b.fmt("KAI_BACKEND_ADAPTER={s}", .{b.getInstallPath(.bin, "kai-adapter-nix")}),
        b.getInstallPath(.bin, "kai"),
        "shell",
        "examples/shell-nix.roc",
    });
    run_nix_example.step.dependOn(install_step);
    run_nix_example.step.dependOn(&run_host_tests.step);
    e2e_step.dependOn(&run_nix_example.step);

    const run_guix_example = b.addSystemCommand(&.{
        "env",
        b.fmt("KAI_BACKEND_ADAPTER={s}", .{b.getInstallPath(.bin, "kai-adapter-guix")}),
        b.getInstallPath(.bin, "kai"),
        "shell",
        "examples/shell-guix.roc",
    });
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
