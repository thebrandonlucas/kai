const std = @import("std");

pub fn build(b: *std.Build) void {
    // e.g. ReleaseSafe, ReleaseFast, ReleaseSmall, Debug
    const optimize = b.standardOptimizeOption(.{});

    // TODO: generalize this to all main desktop arch's
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        // i.e. which C lib impl are we using?
        .abi = .musl,
    });

    const host_lib = b.addLibrary(
        .{ .name = "host", .linkage = .static, .root_module = b.createModule(
            .{
                .root_source_file = b.path("src/host.zig"),
                .target = target,
                .optimize = optimize,
                .pic = true,
            },
        ) },
    );

    host_lib.bundle_compiler_rt = true;

    const check_step = b.step(
        "check",
        "Run formatting and static checks",
    );
    const roc_fmt = b.addSystemCommand(&.{
        "roc",
        "fmt",
        "--check",
        ".",
    });
    check_step.dependOn(&roc_fmt.step);

    const zig_fmt = b.addSystemCommand(&.{
        "zig", "fmt", "--check", "build.zig", "src",
    });
    check_step.dependOn(&zig_fmt.step);

    const check_blueprint = b.addSystemCommand(&.{
        "roc", "check", "blueprint/package.roc",
    });
    check_step.dependOn(&check_blueprint.step);

    const check_platform = b.addSystemCommand(&.{
        "roc", "check", "platform/config.roc",
    });
    check_step.dependOn(&check_platform.step);

    const check_kai = b.addSystemCommand(&.{
        "roc", "check", "kai.roc",
    });
    check_step.dependOn(&check_kai.step);

    const check_cli = b.addSystemCommand(&.{
        "roc", "check", "cli/cli.roc",
    });
    check_step.dependOn(&check_cli.step);

    const check_blueprint_example = b.addSystemCommand(&.{
        "roc", "check", "examples/blueprint-nix-cowsay/main.roc",
    });
    check_step.dependOn(&check_blueprint_example.step);

    const check_cowsay = b.addSystemCommand(&.{
        "roc", "check", "examples/kai-nix-cowsay/main.roc",
    });
    check_step.dependOn(&check_cowsay.step);

    const test_step = b.step(
        "test",
        "Run checks and Roc tests.",
    );
    test_step.dependOn(check_step);

    const test_kai = b.addSystemCommand(&.{
        "roc",
        "test",
        "kai.roc",
    });
    test_kai.step.dependOn(check_step);
    test_step.dependOn(&test_kai.step);

    const test_cli = b.addSystemCommand(&.{
        "roc",
        "test",
        "cli/cli.roc",
    });
    test_cli.step.dependOn(check_step);
    test_step.dependOn(&test_cli.step);

    // Build and copy the Zig host.
    const copy_host = b.addUpdateSourceFiles();
    copy_host.addCopyFileToSource(
        host_lib.getEmittedBin(),
        "platform/targets/x64musl/libhost.a",
    );
    b.getInstallStep().dependOn(&copy_host.step);

    const ci_step = b.step(
        "ci",
        "Run tests and build representative applications",
    );
    ci_step.dependOn(test_step);

    // Avoid shell redirection or mkdir inside a script.
    const prepare_outputs = b.addSystemCommand(&.{
        "mkdir", "-p", "zig-out/bin", "zig-out/tests",
    });
    prepare_outputs.step.dependOn(test_step);
    prepare_outputs.step.dependOn(&copy_host.step);

    const build_cli = b.addSystemCommand(&.{
        "roc",
        "build",
        "cli/cli.roc",
        "--opt=dev",
        "--output=zig-out/bin/kai",
    });
    build_cli.step.dependOn(&prepare_outputs.step);
    ci_step.dependOn(&build_cli.step);

    const build_cowsay = b.addSystemCommand(&.{
        "roc",
        "build",
        "examples/kai-nix-cowsay/main.roc",
        "--opt=dev",
        "--output=zig-out/bin/kai-config",
    });
    build_cowsay.step.dependOn(&prepare_outputs.step);
    ci_step.dependOn(&build_cowsay.step);
}
