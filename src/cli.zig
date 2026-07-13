//! Tiny dependency-free Kai CLI.
const std = @import("std");
const blueprint_mod = @import("blueprint.zig");
const machine = @import("machine.zig");
const registry_mod = @import("command_registry.zig");
const shell_env = @import("shell_env.zig");

const default_config_file = "kai.roc";
const kai_zen = "κινδυνεύεις ἐν καιρῷ τινι οὐκ ἐγεῖραί με\n";

const ConfigCommand = struct {
    cli_name: []const u8,
    path: []const u8,
};

const ShellInit = struct {
    directory: []const u8,
    force: bool = false,
};

const HelpTopic = enum {
    general,
    shell,
    build,
    zen,
};

const Command = union(enum) {
    help: HelpTopic,
    protocol: ConfigCommand,
    shell_init: ShellInit,
    blueprint_list,
    blueprint_get,
    blueprint_set: []const u8,
    zen,
    unavailable: []const u8,
};

const DispatchPlan = struct {
    command_name: []const u8,
    implementation_id: []const u8,
    active_blueprint: blueprint_mod.Blueprint,
    config_path: []const u8,
};

const DispatchResult = union(enum) {
    ok: DispatchPlan,
    command_not_available,
    unsupported_blueprint,
    implementation_not_found,
    implementation_blueprint_mismatch: *const registry_mod.CommandImplementation,
};

const ansi = struct {
    const bold = "\x1b[1m";
    const normal_intensity = "\x1b[22m";
    const command = "\x1b[36m";
    const path = "\x1b[34m";
    const success = "\x1b[32m";
    const foreground_default = "\x1b[39m";
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        writeFmt(init.gpa, init.io, .stderr, "kai: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    _ = it.next(); // argv[0]

    var args = std.array_list.Managed([]const u8).init(init.gpa);
    defer args.deinit();
    while (it.next()) |arg| {
        try args.append(arg);
    }

    const command = parseCommand(args.items) catch |err| switch (err) {
        error.HelpRequested => Command{ .help = .general },
        else => {
            try writeAll(init.io, .stderr, "kai: invalid command usage\n");
            return 1;
        },
    };
    return executeCommand(init.gpa, init.io, init.environ_map, command);
}

fn parseCommand(args: []const []const u8) !Command {
    if (args.len == 0) return .{ .help = .general };
    if (args.len == 1 and isHelp(args[0])) return .{ .help = .general };

    if (std.mem.eql(u8, args[0], "help")) {
        if (args.len == 1) return .{ .help = .general };
        if (args.len == 2 and isShellName(args[1])) return .{ .help = .shell };
        if (args.len == 2 and std.mem.eql(u8, args[1], "build")) return .{ .help = .build };
        if (args.len == 2 and std.mem.eql(u8, args[1], "zen")) return .{ .help = .zen };
        return error.InvalidCommand;
    }

    if (isShellName(args[0])) {
        if (args.len >= 2 and isHelp(args[1])) return .{ .help = .shell };
        if (args.len >= 2 and std.mem.eql(u8, args[1], "init")) {
            const init = parseShellInit(args[2..]) catch |err| switch (err) {
                error.HelpRequested => return .{ .help = .shell },
                else => return err,
            };
            return .{ .shell_init = init };
        }
        return .{ .protocol = .{ .cli_name = "shell", .path = try parseOptionalConfigPath(args[1..]) } };
    }

    if (std.mem.eql(u8, args[0], "build")) {
        if (args.len >= 2 and isHelp(args[1])) return .{ .help = .build };
        return .{ .protocol = .{ .cli_name = "build", .path = try parseOptionalConfigPath(args[1..]) } };
    }

    if (std.mem.eql(u8, args[0], "zen")) {
        if (args.len == 1) return .zen;
        if (args.len == 2 and isHelp(args[1])) return .{ .help = .zen };
        return error.InvalidCommand;
    }

    if (args.len >= 2 and isBlueprintCommandName(args[0])) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "list")) return .blueprint_list;
        if (args.len == 2 and std.mem.eql(u8, args[1], "get")) return .blueprint_get;
        if (args.len == 3 and std.mem.eql(u8, args[1], "set")) return .{ .blueprint_set = args[2] };
        return error.InvalidCommand;
    }

    return .{ .unavailable = args[0] };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isShellName(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "shell") or std.mem.eql(u8, arg, "sh");
}

fn isBlueprintCommandName(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "blueprint") or std.mem.eql(u8, arg, "backend") or std.mem.eql(u8, arg, "adapter");
}

fn parseShellInit(args: []const []const u8) !ShellInit {
    var init = ShellInit{ .directory = "." };
    var saw_directory = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            init.force = true;
        } else if (isHelp(arg)) {
            return error.HelpRequested;
        } else if (!saw_directory) {
            init.directory = arg;
            saw_directory = true;
        } else {
            return error.InvalidCommand;
        }
    }

    return init;
}

fn parseOptionalConfigPath(args: []const []const u8) ![]const u8 {
    return switch (args.len) {
        0 => default_config_file,
        1 => args[0],
        else => error.InvalidCommand,
    };
}

fn executeCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    command: Command,
) !u8 {
    switch (command) {
        .help => |topic| {
            const text = try helpText(allocator, topic, colorEnabled(env_map));
            defer allocator.free(text);
            try writeAll(io, .stdout, text);
            return 0;
        },
        .shell_init => |init| return shellInit(allocator, io, env_map, init),
        .protocol => |config| return dispatchProtocolCommand(allocator, io, env_map, config),
        .blueprint_list => {
            try listBlueprints(allocator, io, env_map);
            return 0;
        },
        .blueprint_get => {
            var selection = try blueprint_mod.selectedBlueprint(allocator, io, env_map);
            if (selection) |*sel| {
                defer sel.deinit(allocator);
                try writeFmt(allocator, io, .stdout, "{s}\n", .{sel.setting});
            } else {
                try writeAll(io, .stdout, "none\n");
            }
            return 0;
        },
        .blueprint_set => |blueprint| {
            try blueprint_mod.validateBlueprintSetting(blueprint);
            try blueprint_mod.writeConfiguredBlueprint(allocator, io, blueprint);
            try writeFmt(allocator, io, .stdout, "{s}\n", .{blueprint});
            return 0;
        },
        .zen => {
            try writeAll(io, .stdout, zenText());
            return 0;
        },
        .unavailable => |name| {
            try writeFmt(allocator, io, .stderr, "kai: command not available: {s}\n", .{name});
            return 1;
        },
    }
}

fn shellInit(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    init: ShellInit,
) !u8 {
    const config_path = try std.fs.path.join(allocator, &.{ init.directory, default_config_file });
    defer allocator.free(config_path);

    if (!init.force) {
        std.Io.Dir.cwd().access(io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (fileExists(io, config_path)) {
            try writeFmt(allocator, io, .stderr, "kai: refusing to overwrite {s}; pass --force\n", .{config_path});
            return 1;
        }
    }

    try std.Io.Dir.cwd().createDirPath(io, init.directory);

    const name = try defaultShellName(allocator, init.directory);
    defer allocator.free(name);

    const platform_path = try platformPathForStarter(allocator, init.directory);
    defer allocator.free(platform_path);
    const config = try starterKaiRoc(allocator, name, platform_path);
    defer allocator.free(config);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config });

    const shell_dir = try std.fs.path.join(allocator, &.{ init.directory, shell_env.shell_workspace_dir });
    defer allocator.free(shell_dir);
    try std.Io.Dir.cwd().createDirPath(io, shell_dir);

    const flake_path = try std.fs.path.join(allocator, &.{ init.directory, shell_env.nix_flake_path });
    defer allocator.free(flake_path);
    const flake = try shell_env.renderNixFlake(allocator, name, &.{});
    defer allocator.free(flake);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = flake_path, .data = flake });

    const use_color = colorEnabled(env_map);
    try writeStatusLine(allocator, io, use_color, "wrote", config_path);
    try writeStatusLine(allocator, io, use_color, "wrote", flake_path);
    const next = try styledLiteral(allocator, use_color, "next:", .success);
    defer allocator.free(next);
    const command = try styledLiteral(allocator, use_color, "kai shell", .command);
    defer allocator.free(command);
    try writeFmt(allocator, io, .stdout, "{s} edit packages in {s}, then run `{s}`\n", .{ next, default_config_file, command });
    return 0;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn defaultShellName(allocator: std.mem.Allocator, directory: []const u8) ![]u8 {
    const base = std.fs.path.basename(directory);
    const raw = if (base.len == 0 or std.mem.eql(u8, base, ".")) "kai" else base;
    var out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |ch, i| {
        out[i] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '+' => ch,
            else => '-',
        };
    }
    return out;
}

fn starterKaiRoc(allocator: std.mem.Allocator, name: []const u8, platform_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\app [config] {{ kai: platform "{s}" }}
        \\
        \\config = [
        \\    Shell({{
        \\        name: "{s}",
        \\        # `packages` is a Roc header keyword in this compiler, so shell configs use `pkgs`.
        \\        pkgs: [],
        \\    }}),
        \\]
        \\
    , .{ platform_path, name });
}

fn platformPathForStarter(allocator: std.mem.Allocator, directory: []const u8) ![]u8 {
    if (directory.len == 0 or std.mem.eql(u8, directory, ".")) {
        return allocator.dupe(u8, "./platform/config.roc");
    }

    var depth: usize = 0;
    var it = std.mem.tokenizeAny(u8, directory, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) continue;
        depth += 1;
    }
    if (depth == 0) return allocator.dupe(u8, "./platform/config.roc");

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (0..depth) |_| try out.appendSlice("../");
    try out.appendSlice("platform/config.roc");
    return out.toOwnedSlice();
}

const StyledKind = enum { heading, command, path, success };

fn helpText(allocator: std.mem.Allocator, topic: HelpTopic, use_color: bool) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    switch (topic) {
        .general => try appendGeneralHelp(&out, use_color),
        .shell => try appendShellHelp(&out, use_color),
        .build => try appendBuildHelp(&out, use_color),
        .zen => try appendZenHelp(&out, use_color),
    }

    return out.toOwnedSlice();
}

fn appendGeneralHelp(out: *std.array_list.Managed(u8), use_color: bool) !void {
    try out.appendSlice("A friendly frontend for determinate computing\n\n");
    try appendStyled(out, use_color, "Usage:", .heading);
    try out.appendSlice(" ");
    try appendStyled(out, use_color, "kai", .command);
    try out.appendSlice(" ");
    try appendStyled(out, use_color, "<command> [...flags] [...args]", .heading);
    try out.appendSlice("\n\n");
    try appendStyled(out, use_color, "Commands:", .heading);
    try out.appendSlice("\n");
    try appendCommandRow(out, use_color, "shell (sh)", "Create or manage persistent or temporary shells");
    try appendCommandRow(out, use_color, "build [kai.roc]", "render " ++ machine.machine_flake_path ++ " and build machine image");
    try appendCommandRow(out, use_color, "blueprint list|get|set", "select the active execution blueprint");
    try appendCommandRow(out, use_color, "zen", "print kai zen");
    try out.appendSlice("\n");
    try out.appendSlice("kai is a tool to help you harness the power of determinate computing by\n");
    try out.appendSlice("wrapping nix commands in a friendly interface.\n\n");
    try appendStyled(out, use_color, "Some things you can do:", .heading);
    try out.appendSlice("\n\n");
    try appendExample(out, use_color, "kai shell init", "Create a starter kai.roc and generated " ++ shell_env.nix_flake_path ++ ".");
    try appendExample(out, use_color, "kai shell", "Render the shell from kai.roc and enter it through the active blueprint.");
    try appendExample(out, use_color, "kai build", "Render " ++ machine.machine_flake_path ++ " and build the configured machine image.");
    try appendStyled(out, use_color, "Flags:", .heading);
    try out.appendSlice("\n  -h, --help                             print help information\n");
}

fn appendShellHelp(out: *std.array_list.Managed(u8), use_color: bool) !void {
    try out.appendSlice("Create, initialize, and enter the top-level dev shell from kai.roc. `sh` is an alias for `shell`.\n\n");
    try appendStyled(out, use_color, "Usage:", .heading);
    try out.appendSlice("\n  ");
    try appendStyled(out, use_color, "kai shell [kai.roc]", .command);
    try out.appendSlice("\n  ");
    try appendStyled(out, use_color, "kai shell init [directory]", .command);
    try out.appendSlice("\n  ");
    try appendStyled(out, use_color, "kai sh init [directory]", .command);
    try out.appendSlice("\n\n");
    try appendStyled(out, use_color, "Commands:", .heading);
    try out.appendSlice("\n");
    try appendCommandRow(out, use_color, "kai shell init", "Create starter kai.roc and " ++ shell_env.nix_flake_path ++ " files");
    try out.appendSlice("\n");
    try appendStyled(out, use_color, "Examples:", .heading);
    try out.appendSlice("\n");
    try appendCommandRow(out, use_color, "kai shell", "Enter the shell described by kai.roc");
    try appendCommandRow(out, use_color, "kai shell examples/shell.roc", "Enter a shell from another Roc config");
    try appendCommandRow(out, use_color, "kai shell init my-app", "Create starter files");
    try out.appendSlice("\n");
    try appendStyled(out, use_color, "Flags:", .heading);
    try out.appendSlice("\n  --force                                overwrite an existing kai.roc during init\n  -h, --help                             print help information\n");
}

fn appendBuildHelp(out: *std.array_list.Managed(u8), use_color: bool) !void {
    try out.appendSlice("Render " ++ machine.machine_flake_path ++ " and build the configured machine image output.\n\n");
    try appendStyled(out, use_color, "Usage:", .heading);
    try out.appendSlice("\n  ");
    try appendStyled(out, use_color, "kai build [kai.roc]", .command);
    try out.appendSlice("\n\n`kai build` expects the selected Roc config to contain a MachineBuild entry.\n\n");
    try appendStyled(out, use_color, "Examples:", .heading);
    try out.appendSlice("\n");
    try appendCommandRow(out, use_color, "kai build", "Build the machine image from kai.roc");
    try appendCommandRow(out, use_color, "kai build examples/shell.roc", "Build from another Roc config");
    try out.appendSlice("\n");
    try appendStyled(out, use_color, "Flags:", .heading);
    try out.appendSlice("\n  -h, --help                             print help information\n");
}

fn appendZenHelp(out: *std.array_list.Managed(u8), use_color: bool) !void {
    try out.appendSlice("Print kai zen.\n\n");
    try appendStyled(out, use_color, "Usage:", .heading);
    try out.appendSlice("\n  ");
    try appendStyled(out, use_color, "kai zen", .command);
    try out.appendSlice("\n\n");
    try appendStyled(out, use_color, "Examples:", .heading);
    try out.appendSlice("\n");
    try appendCommandRow(out, use_color, "kai zen", "Print kai zen");
    try out.appendSlice("\n");
    try appendStyled(out, use_color, "Flags:", .heading);
    try out.appendSlice("\n  -h, --help                             print help information\n");
}

fn zenText() []const u8 {
    return kai_zen;
}

fn appendCommandRow(out: *std.array_list.Managed(u8), use_color: bool, command: []const u8, description: []const u8) !void {
    try out.appendSlice("  ");
    try appendStyled(out, use_color, command, .command);
    const width: usize = 34;
    const pad = if (command.len < width) width - command.len else 2;
    try out.appendNTimes(' ', pad);
    try out.appendSlice(description);
    try out.append('\n');
}

fn appendExample(out: *std.array_list.Managed(u8), use_color: bool, command: []const u8, description: []const u8) !void {
    try out.appendSlice("    ");
    try appendStyled(out, use_color, command, .command);
    try out.appendSlice("\n        ");
    try out.appendSlice(description);
    try out.appendSlice("\n\n");
}

fn appendStyled(out: *std.array_list.Managed(u8), use_color: bool, text: []const u8, kind: StyledKind) !void {
    if (!use_color) {
        try out.appendSlice(text);
        return;
    }
    const open = switch (kind) {
        .heading => ansi.bold,
        .command => ansi.command,
        .path => ansi.path,
        .success => ansi.success,
    };
    const close = switch (kind) {
        .heading => ansi.normal_intensity,
        .command, .path, .success => ansi.foreground_default,
    };
    try out.appendSlice(open);
    try out.appendSlice(text);
    try out.appendSlice(close);
}

fn styledLiteral(allocator: std.mem.Allocator, use_color: bool, text: []const u8, kind: StyledKind) ![]u8 {
    if (!use_color) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ switch (kind) {
        .heading => ansi.bold,
        .command => ansi.command,
        .path => ansi.path,
        .success => ansi.success,
    }, text, switch (kind) {
        .heading => ansi.normal_intensity,
        .command, .path, .success => ansi.foreground_default,
    } });
}

fn writeStatusLine(allocator: std.mem.Allocator, io: std.Io, use_color: bool, status: []const u8, path: []const u8) !void {
    const styled_status = try styledLiteral(allocator, use_color, status, .success);
    defer allocator.free(styled_status);
    const styled_path = try styledLiteral(allocator, use_color, path, .path);
    defer allocator.free(styled_path);
    try writeFmt(allocator, io, .stdout, "{s} {s}\n", .{ styled_status, styled_path });
}

fn colorEnabled(env_map: *std.process.Environ.Map) bool {
    if (env_map.get("NO_COLOR")) |value| {
        _ = value;
        return false;
    }
    if (env_map.get("KAI_COLOR")) |value| {
        if (std.mem.eql(u8, value, "never")) return false;
    }
    return true;
}

fn dispatchProtocolCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    config: ConfigCommand,
) !u8 {
    var active = try blueprint_mod.selectedBlueprint(allocator, io, env_map) orelse {
        try writeAll(io, .stderr, "kai: missing active blueprint; run `kai blueprint set nix` or set KAI_BLUEPRINT\n");
        return 1;
    };
    defer active.deinit(allocator);

    const override_id = try implementationOverride(allocator, env_map, config.cli_name);
    defer if (override_id) |id| allocator.free(id);

    const result = planProtocolDispatch(
        registry_mod.default_protocol_registry,
        config.cli_name,
        config.path,
        active.blueprint,
        override_id,
    );

    return switch (result) {
        .ok => |plan| runRocConfigProtocolCommand(io, env_map, plan.config_path, plan.command_name),
        .command_not_available, .implementation_not_found => blk: {
            try writeFmt(allocator, io, .stderr, "kai: command not available: {s}\n", .{config.cli_name});
            break :blk 1;
        },
        .unsupported_blueprint => blk: {
            const command = registry_mod.default_protocol_registry.lookup(config.cli_name).?;
            try writeFmt(allocator, io, .stderr, "kai: blueprint {s} does not support protocol command {s}\n", .{ active.blueprintName(), command.name });
            break :blk 1;
        },
        .implementation_blueprint_mismatch => |implementation| blk: {
            const command = registry_mod.default_protocol_registry.lookup(config.cli_name).?;
            try writeFmt(
                allocator,
                io,
                .stderr,
                "kai: implementation blueprint mismatch: command {s} requires {s}, active blueprint is {s}\n",
                .{ command.name, implementation.blueprint.name(), active.blueprintName() },
            );
            break :blk 1;
        },
    };
}

fn planProtocolDispatch(
    registry: registry_mod.ProtocolRegistry,
    cli_name: []const u8,
    config_path: []const u8,
    active_blueprint: blueprint_mod.Blueprint,
    override_id: ?[]const u8,
) DispatchResult {
    const command = registry.lookup(cli_name) orelse return .command_not_available;
    const selected = registry.selectImplementation(command.name, active_blueprint, override_id);
    return switch (selected) {
        .ok => |implementation| .{ .ok = .{
            .command_name = command.name,
            .implementation_id = implementation.id,
            .active_blueprint = active_blueprint,
            .config_path = config_path,
        } },
        .command_not_registered => .command_not_available,
        .blueprint_unsupported => .unsupported_blueprint,
        .implementation_not_found => .implementation_not_found,
        .implementation_blueprint_mismatch => |implementation| .{ .implementation_blueprint_mismatch = implementation },
    };
}

fn implementationOverride(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cli_name: []const u8,
) !?[]u8 {
    const command = registry_mod.default_protocol_registry.lookup(cli_name) orelse return null;
    const env_name = try registry_mod.cliImplementationOverrideName(allocator, command.name);
    defer allocator.free(env_name);
    if (env_map.get(env_name)) |value| {
        if (value.len != 0) return try allocator.dupe(u8, value);
    }
    return null;
}

fn runRocConfigProtocolCommand(
    io: std.Io,
    env_map: *std.process.Environ.Map,
    config_path: []const u8,
    command_name: []const u8,
) !u8 {
    const roc_exe = env_map.get("KAI_ROC") orelse "roc";
    const argv = rocConfigArgv(roc_exe, config_path, command_name);
    return runProcessStatus(io, &argv);
}

fn rocConfigArgv(roc_exe: []const u8, config_path: []const u8, command_name: []const u8) [4][]const u8 {
    return .{ roc_exe, config_path, "--", command_name };
}

fn runProcessStatus(io: std.Io, argv: []const []const u8) !u8 {
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

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

fn listBlueprints(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !void {
    var selection = try blueprint_mod.selectedBlueprint(allocator, io, env_map);
    if (selection) |*sel| {
        defer sel.deinit(allocator);
        try writeFmt(allocator, io, .stdout, "current\t{s}\t{s}\t{s}\tblueprint={s}\n", .{ sel.source, sel.setting, sel.blueprint_executable, sel.blueprintName() });
    } else {
        try writeAll(io, .stdout, "current\tnone\n");
    }

    var found = false;
    for (blueprint_mod.builtin_blueprints) |blueprint| {
        const resolved = try blueprint_mod.resolveBlueprint(allocator, io, blueprint.name);
        defer allocator.free(resolved);
        found = true;
        try writeFmt(allocator, io, .stdout, "{s}\t{s}\tblueprint={s}\n", .{ blueprint.name, resolved, blueprint.blueprint.name() });
    }

    if (!found) {
        try writeAll(io, .stdout, "built\tnone-found-next-to-kai\n");
    }
}

const Stream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    try file.writeStreamingAll(io, bytes);
}

fn writeFmt(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: Stream,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try writeAll(io, stream, bytes);
}

test "parses supported commands" {
    try std.testing.expectEqual(HelpTopic.general, (try parseCommand(&.{"help"})).help);
    try std.testing.expectEqual(HelpTopic.shell, (try parseCommand(&.{ "help", "shell" })).help);
    try std.testing.expectEqual(HelpTopic.build, (try parseCommand(&.{ "build", "--help" })).help);
    try std.testing.expectEqual(HelpTopic.zen, (try parseCommand(&.{ "help", "zen" })).help);
    try std.testing.expectEqual(HelpTopic.zen, (try parseCommand(&.{ "zen", "--help" })).help);
    try std.testing.expectEqual(Command.zen, try parseCommand(&.{"zen"}));

    const shell_default = try parseCommand(&.{"shell"});
    try std.testing.expectEqualStrings("shell", shell_default.protocol.cli_name);
    try std.testing.expectEqualStrings(default_config_file, shell_default.protocol.path);
    const shell_file = try parseCommand(&.{ "sh", "examples/shell.roc" });
    try std.testing.expectEqualStrings("examples/shell.roc", shell_file.protocol.path);

    const init = try parseCommand(&.{ "shell", "init", "my-app", "--force" });
    try std.testing.expectEqualStrings("my-app", init.shell_init.directory);
    try std.testing.expect(init.shell_init.force);

    const build_default = try parseCommand(&.{"build"});
    try std.testing.expectEqualStrings("build", build_default.protocol.cli_name);
    try std.testing.expectEqualStrings(default_config_file, build_default.protocol.path);
    const build_file = try parseCommand(&.{ "build", "examples/shell.roc" });
    try std.testing.expectEqualStrings("examples/shell.roc", build_file.protocol.path);

    try std.testing.expectEqual(Command.blueprint_list, try parseCommand(&.{ "blueprint", "list" }));
    try std.testing.expectEqual(Command.blueprint_get, try parseCommand(&.{ "blueprint", "get" }));
    try std.testing.expectEqual(Command.blueprint_list, try parseCommand(&.{ "backend", "list" }));
    try std.testing.expectEqual(Command.blueprint_list, try parseCommand(&.{ "adapter", "list" }));

    const command = try parseCommand(&.{ "blueprint", "set", "nix" });
    try std.testing.expect(std.mem.eql(u8, command.blueprint_set, "nix"));
}

test "rejects invalid command usage" {
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "shell", "a", "b" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "build", "a", "b" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "shell", "init", "one", "two" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "blueprint", "delete" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "adapter", "delete" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "backend", "delete" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "zen", "one" }));
}

test "preserves unavailable command name" {
    const command = try parseCommand(&.{"deploy"});
    try std.testing.expectEqualStrings("deploy", command.unavailable);
}

test "builds roc config argv with protocol command name" {
    const argv = rocConfigArgv("roc", "examples/shell.roc", "machine.build");
    try std.testing.expectEqualStrings("roc", argv[0]);
    try std.testing.expectEqualStrings("examples/shell.roc", argv[1]);
    try std.testing.expectEqualStrings("--", argv[2]);
    try std.testing.expectEqualStrings("machine.build", argv[3]);
}

test "run process status returns child exit code" {
    const code = try runProcessStatus(std.testing.io, &.{ "sh", "-c", "exit 5" });
    try std.testing.expectEqual(@as(u8, 5), code);
}

test "styled help uses bold headers and ANSI command color" {
    const text = try helpText(std.testing.allocator, .general, true);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ansi.bold ++ "Usage:" ++ ansi.normal_intensity) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ansi.command ++ "kai" ++ ansi.foreground_default) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "target") == null);
}

test "prints and documents kai zen" {
    try std.testing.expectEqualStrings("κινδυνεύεις ἐν καιρῷ τινι οὐκ ἐγεῖραί με\n", zenText());

    const general = try helpText(std.testing.allocator, .general, false);
    defer std.testing.allocator.free(general);
    try std.testing.expect(std.mem.indexOf(u8, general, "zen") != null);
    try std.testing.expect(std.mem.indexOf(u8, general, "print kai zen") != null);

    const zen_help = try helpText(std.testing.allocator, .zen, false);
    defer std.testing.allocator.free(zen_help);
    try std.testing.expect(std.mem.indexOf(u8, zen_help, "Print kai zen.") != null);
    try std.testing.expect(std.mem.indexOf(u8, zen_help, "kai zen") != null);
}

test "plans shell command dispatch" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "shell", "examples/shell.roc", .nix, null);
    switch (result) {
        .ok => |plan| {
            try std.testing.expectEqualStrings("shell", plan.command_name);
            try std.testing.expectEqualStrings("shell.default.nix", plan.implementation_id);
            try std.testing.expectEqual(blueprint_mod.Blueprint.nix, plan.active_blueprint);
        },
        else => return error.TestExpectedShellDispatch,
    }
}

test "plans build alias dispatch to machine.build" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "build", "kai.roc", .nix, null);
    switch (result) {
        .ok => |plan| {
            try std.testing.expectEqualStrings("machine.build", plan.command_name);
            try std.testing.expectEqualStrings("machine.build.default.nix", plan.implementation_id);
        },
        else => return error.TestExpectedBuildDispatch,
    }
}

test "reports unsupported blueprint for machine build on guix" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "build", "kai.roc", .guix, null);
    try std.testing.expectEqual(DispatchResult.unsupported_blueprint, result);
}

test "reports command not registered" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "deploy", "kai.roc", .nix, null);
    try std.testing.expectEqual(DispatchResult.command_not_available, result);
}

test "reports implementation blueprint mismatch" {
    const result = planProtocolDispatch(registry_mod.default_protocol_registry, "shell", "kai.roc", .guix, "shell.default.nix");
    switch (result) {
        .implementation_blueprint_mismatch => |implementation| try std.testing.expectEqualStrings("shell.default.nix", implementation.id),
        else => return error.TestExpectedBlueprintMismatch,
    }
}
