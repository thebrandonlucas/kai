//! Tiny dependency-free Kai CLI.
const std = @import("std");
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
    zen,
};

const Command = union(enum) {
    help: HelpTopic,
    shell: ConfigCommand,
    shell_init: ShellInit,
    zen,
    unavailable: []const u8,
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
        return .{ .shell = .{ .cli_name = "shell", .path = try parseOptionalConfigPath(args[1..]) } };
    }

    if (std.mem.eql(u8, args[0], "zen")) {
        if (args.len == 1) return .zen;
        if (args.len == 2 and isHelp(args[1])) return .{ .help = .zen };
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
        .shell => |config| return runNixBlueprintShell(allocator, io, env_map, config.path),
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

    const config = try starterKaiRoc(allocator, name);
    defer allocator.free(config);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config });

    const kai_config_dir = try std.fs.path.join(allocator, &.{ init.directory, kai_dir });
    defer allocator.free(kai_config_dir);
    try std.Io.Dir.cwd().createDirPath(io, kai_config_dir);

    const bindings_path = try std.fs.path.join(allocator, &.{ init.directory, nix_bindings_path });
    defer allocator.free(bindings_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bindings_path, .data = default_nix_bindings_source });

    const shell_dir = try std.fs.path.join(allocator, &.{ init.directory, shell_env.shell_workspace_dir });
    defer allocator.free(shell_dir);
    try std.Io.Dir.cwd().createDirPath(io, shell_dir);

    const use_color = colorEnabled(env_map);
    try writeStatusLine(allocator, io, use_color, "wrote", config_path);
    try writeStatusLine(allocator, io, use_color, "wrote", bindings_path);
    const next = try styledLiteral(allocator, use_color, "next:", .success);
    defer allocator.free(next);
    const command = try styledLiteral(allocator, use_color, "kai shell", .command);
    defer allocator.free(command);
    try writeFmt(allocator, io, .stdout, "{s} edit requirements in {s} and bindings in {s}, then run `{s}`\n", .{ next, default_config_file, nix_bindings_path, command });
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

fn starterKaiRoc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\package [workspace] {{
        \\    blueprint: "{s}",
        \\}}
        \\
        \\import blueprint.Blueprint
        \\import blueprint.Environment
        \\import blueprint.Requirement
        \\import blueprint.Target
        \\
        \\# Add requirements like:
        \\# zig = Requirement.new({{ id: "zig", display_name: "Zig" }})
        \\
        \\workspace : Blueprint.Draft
        \\workspace = Blueprint.workspace(
        \\    {{
        \\        name: "{s}",
        \\        target_systems: [Target.X86_64Linux],
        \\        envs: [Environment.new({{ name: "default", requirements: [] }})],
        \\    }},
        \\)
        \\
    , .{ default_blueprint_url, name });
}

const StyledKind = enum { heading, command, path, success };

fn helpText(allocator: std.mem.Allocator, topic: HelpTopic, use_color: bool) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    switch (topic) {
        .general => try appendGeneralHelp(&out, use_color),
        .shell => try appendShellHelp(&out, use_color),
        .zen => try appendZenHelp(&out, use_color),
    }

    return out.toOwnedSlice();
}

fn appendGeneralHelp(out: *std.array_list.Managed(u8), use_color: bool) !void {
    try out.appendSlice("A friendly roc-blueprint shell frontend\n\n");
    try appendStyled(out, use_color, "Usage:", .heading);
    try out.appendSlice(" ");
    try appendStyled(out, use_color, "kai", .command);
    try out.appendSlice(" ");
    try appendStyled(out, use_color, "<command> [...flags] [...args]", .heading);
    try out.appendSlice("\n\n");
    try appendStyled(out, use_color, "Commands:", .heading);
    try out.appendSlice("\n");
    try appendCommandRow(out, use_color, "shell (sh)", "render and enter a roc-blueprint Nix shell");
    try appendCommandRow(out, use_color, "zen", "print kai zen");
    try out.appendSlice("\n");
    try out.appendSlice("kai reads a package-style roc-blueprint workspace from kai.roc, renders it to Nix, and runs nix develop.\n\n");
    try appendStyled(out, use_color, "Some things you can do:", .heading);
    try out.appendSlice("\n\n");
    try appendExample(out, use_color, "kai shell init", "Create a starter kai.roc and editable " ++ nix_bindings_path ++ ".");
    try appendExample(out, use_color, "kai shell", "Render the shell from kai.roc and enter it.");
    try appendStyled(out, use_color, "Flags:", .heading);
    try out.appendSlice("\n  -h, --help                             print help information\n");
}

fn appendShellHelp(out: *std.array_list.Managed(u8), use_color: bool) !void {
    try out.appendSlice("Create, initialize, and enter the top-level dev shell from a roc-blueprint package. `sh` is an alias for `shell`.\n\n");
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
    try appendCommandRow(out, use_color, "kai shell init", "Create starter kai.roc and " ++ nix_bindings_path ++ " bindings");
    try out.appendSlice("\n");
    try appendStyled(out, use_color, "Examples:", .heading);
    try out.appendSlice("\n");
    try appendCommandRow(out, use_color, "kai shell", "Enter the shell described by kai.roc");
    try appendCommandRow(out, use_color, "kai shell examples/hello-shell/main.roc", "Enter a shell from another Roc config");
    try appendCommandRow(out, use_color, "kai shell init my-app", "Create starter files");
    try out.appendSlice("\n");
    try appendStyled(out, use_color, "Flags:", .heading);
    try out.appendSlice("\n  --force                                overwrite an existing kai.roc during init\n  -h, --help                             print help information\n");
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

const kai_dir = ".kai";
const nix_bindings_path = kai_dir ++ "/nix.roc";
const render_nix_path = kai_dir ++ "/render-nix.roc";
const default_blueprint_url = "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint/HmTRQhvSpRQsj78WCR7j5y3anhqMVB4zuMejydrdAGeV.tar.zst";
const default_blueprint_nix_url = "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint-nix/5stkC8nuQYzCjQueDhBLQrFPvfk6MP1byVq8nR3ET72h.tar.zst";

fn runNixBlueprintShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    config_path: []const u8,
) !u8 {
    try std.Io.Dir.cwd().createDirPath(io, kai_dir);
    try ensureDefaultNixBindings(io);

    const wrapper = try renderNixWrapper(allocator, io, config_path);
    defer allocator.free(wrapper);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = render_nix_path, .data = wrapper });

    const source = if (useRocNixRenderer(env_map)) blk: {
        break :blk runRenderNixWrapper(allocator, io, env_map) catch return 1;
    } else blk: {
        break :blk renderNixSourceFallback(allocator, io, config_path) catch |err| {
            try writeFmt(allocator, io, .stderr, "kai: {s}\n", .{@errorName(err)});
            return 1;
        };
    };
    defer allocator.free(source);

    const prepared = try shell_env.prepareNixSource(allocator, io, "default", source);
    defer prepared.deinit(allocator);

    if (prepared.generated_path) |path| {
        try writeFmt(allocator, io, .stdout, "{s} {s}\n", .{ if (prepared.wrote) "wrote" else "using", path });
    }

    return runNixDevelop(io, prepared.target);
}

fn ensureDefaultNixBindings(io: std.Io) !void {
    std.Io.Dir.cwd().access(io, nix_bindings_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nix_bindings_path, .data = default_nix_bindings_source });
            return;
        },
        else => return err,
    };
}

fn renderNixWrapper(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) ![]u8 {
    const user_source = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1024 * 1024));
    defer allocator.free(user_source);
    const user_body = stripPackageHeader(user_source) orelse return error.InvalidKaiPackage;

    const bindings_source = try std.Io.Dir.cwd().readFileAlloc(io, nix_bindings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(bindings_source);

    return std.fmt.allocPrint(allocator,
        \\app [main!] {{
        \\    kai: platform "../platform/main.roc",
        \\    blueprint: "{s}",
        \\    blueprint_nix: "{s}",
        \\}}
        \\
        \\import kai.Stdout
        \\import blueprint_nix.Nix
        \\
        \\{s}
        \\
        \\{s}
        \\
        \\main! : List(Str) => I32
        \\main! = |_args|
        \\    match Blueprint.validate(workspace) {{
        \\        Err(_) => {{
        \\            _ = Stdout.line!("kai: invalid blueprint workspace")
        \\            1
        \\        }}
        \\        Ok(valid) =>
        \\            match Nix.render(valid, nix_config) {{
        \\                Err(_) => {{
        \\                    _ = Stdout.line!("kai: invalid nix blueprint config; edit .kai/nix.roc")
        \\                    1
        \\                }}
        \\                Ok(source) => {{
        \\                    _ = Stdout.line!(source)
        \\                    0
        \\                }}
        \\            }}
        \\    }}
        \\
    , .{ default_blueprint_url, default_blueprint_nix_url, std.mem.trim(u8, user_body, " \t\r\n"), std.mem.trim(u8, bindings_source, " \t\r\n") });
}

fn useRocNixRenderer(env_map: *std.process.Environ.Map) bool {
    if (env_map.get("KAI_USE_ROC_BLUEPRINT_RENDERER")) |value| {
        return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
    }
    return false;
}

fn runRenderNixWrapper(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
) ![]u8 {
    const roc_exe = env_map.get("KAI_ROC") orelse "roc";
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ roc_exe, render_nix_path },
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return result.stdout;
            defer allocator.free(result.stdout);
            if (result.stdout.len != 0) try writeAll(io, .stderr, result.stdout);
            if (result.stderr.len != 0) try writeAll(io, .stderr, result.stderr);
            return error.RenderNixFailed;
        },
        .signal, .stopped, .unknown => {
            defer allocator.free(result.stdout);
            if (result.stdout.len != 0) try writeAll(io, .stderr, result.stdout);
            if (result.stderr.len != 0) try writeAll(io, .stderr, result.stderr);
            return error.RenderNixFailed;
        },
    }
}

fn stripPackageHeader(source: []const u8) ?[]const u8 {
    var index = skipRocHeaderTrivia(source);
    if (!std.mem.startsWith(u8, source[index..], "package")) return null;
    index += "package".len;

    const open_offset = std.mem.indexOfScalarPos(u8, source, index, '{') orelse return null;
    var depth: usize = 0;
    var cursor = open_offset;
    while (cursor < source.len) : (cursor += 1) {
        switch (source[cursor]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    cursor += 1;
                    while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
                    return source[cursor..];
                }
            },
            else => {},
        }
    }
    return null;
}

fn skipRocHeaderTrivia(source: []const u8) usize {
    var index: usize = 0;
    while (index < source.len) {
        while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
        if (index >= source.len or source[index] != '#') break;
        while (index < source.len and source[index] != '\n') : (index += 1) {}
    }
    return index;
}

const default_nix_bindings_source =
    "# Kai-managed editable Nix bindings.\n" ++
    "# Default convention: requirement id == nixpkgs package attribute.\n" ++
    "# Edit this file when a requirement needs a different Nix package path.\n\n" ++
    "nix_config : Nix.Config\n" ++
    "nix_config = Nix.config(\n" ++
    "    {\n" ++
    "        nixpkgs: Nix.github_input(\"nixpkgs\", \"NixOS\", \"nixpkgs\", \"nixos-unstable\"),\n" ++
    "        bindings: default_bindings(workspace),\n" ++
    "    },\n" ++
    ")\n\n" ++
    "default_bindings : Blueprint.Draft -> List(Nix.Binding)\n" ++
    "default_bindings = |draft|\n" ++
    "    collect_env_requirements(draft.envs, []).map(|requirement| Nix.bind(requirement, \"nixpkgs\", [Requirement.id(requirement)]))\n\n" ++
    "collect_env_requirements : List(Environment), List(Requirement) -> List(Requirement)\n" ++
    "collect_env_requirements = |envs, seen|\n" ++
    "    match envs {\n" ++
    "        [] => seen\n" ++
    "        [env, .. as rest] => collect_env_requirements(rest, append_new_requirements(env.requirements, seen))\n" ++
    "    }\n\n" ++
    "append_new_requirements : List(Requirement), List(Requirement) -> List(Requirement)\n" ++
    "append_new_requirements = |requirements, seen|\n" ++
    "    match requirements {\n" ++
    "        [] => seen\n" ++
    "        [requirement, .. as rest] =>\n" ++
    "            if seen.any(|existing| Requirement.id(existing) == Requirement.id(requirement)) {\n" ++
    "                append_new_requirements(rest, seen)\n" ++
    "            } else {\n" ++
    "                append_new_requirements(rest, seen.append(requirement))\n" ++
    "            }\n" ++
    "    }\n";

const RequirementDef = struct {
    name: []u8,
    id: []u8,

    fn deinit(self: RequirementDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.id);
    }
};

const EnvironmentDef = struct {
    name: []u8,
    requirements: []const []u8,

    fn deinit(self: EnvironmentDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.requirements) |requirement| allocator.free(requirement);
        allocator.free(self.requirements);
    }
};

const BindingDef = struct {
    requirement_id: []u8,
    path: []const []u8,

    fn deinit(self: BindingDef, allocator: std.mem.Allocator) void {
        allocator.free(self.requirement_id);
        for (self.path) |segment| allocator.free(segment);
        allocator.free(self.path);
    }
};

const WorkspaceDef = struct {
    name: []u8,
    targets: []const []u8,
    requirements: []const RequirementDef,
    environments: []const EnvironmentDef,

    fn deinit(self: WorkspaceDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.targets) |target| allocator.free(target);
        allocator.free(self.targets);
        for (self.requirements) |requirement| requirement.deinit(allocator);
        allocator.free(self.requirements);
        for (self.environments) |environment| environment.deinit(allocator);
        allocator.free(self.environments);
    }
};

fn renderNixSourceFallback(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) ![]u8 {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    var workspace = try parseWorkspaceSource(allocator, source);
    defer workspace.deinit(allocator);

    const bindings_source = try std.Io.Dir.cwd().readFileAlloc(io, nix_bindings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(bindings_source);
    const bindings = try parseBindingDefs(allocator, bindings_source, workspace.requirements);
    defer {
        for (bindings) |binding| binding.deinit(allocator);
        allocator.free(bindings);
    }

    return renderFallbackFlake(allocator, workspace, bindings);
}

fn parseWorkspaceSource(allocator: std.mem.Allocator, source: []const u8) !WorkspaceDef {
    const workspace_body = findCallBody(source, "Blueprint.workspace") orelse return error.InvalidKaiWorkspace;
    const name = try parseStringField(allocator, workspace_body, "name");
    errdefer allocator.free(name);
    const targets = try parseTargets(allocator, workspace_body);
    errdefer {
        for (targets) |target| allocator.free(target);
        allocator.free(targets);
    }
    const requirements = try parseRequirementDefs(allocator, source);
    errdefer {
        for (requirements) |requirement| requirement.deinit(allocator);
        allocator.free(requirements);
    }
    const environments = try parseEnvironments(allocator, source, requirements);
    errdefer {
        for (environments) |environment| environment.deinit(allocator);
        allocator.free(environments);
    }
    if (name.len == 0 or targets.len == 0 or environments.len == 0) return error.InvalidKaiWorkspace;
    return .{ .name = name, .targets = targets, .requirements = requirements, .environments = environments };
}

fn parseRequirementDefs(allocator: std.mem.Allocator, source: []const u8) ![]const RequirementDef {
    var out = std.array_list.Managed(RequirementDef).init(allocator);
    errdefer {
        for (out.items) |requirement| requirement.deinit(allocator);
        out.deinit();
    }

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "Requirement.new")) |pos| {
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..pos], '\n')) |nl| nl + 1 else 0;
        const eq = std.mem.indexOfScalarPos(u8, source, line_start, '=') orelse {
            cursor = pos + 1;
            continue;
        };
        if (eq > pos) {
            cursor = pos + 1;
            continue;
        }
        const name = std.mem.trim(u8, source[line_start..eq], " \t\r\n");
        const body = findCallBody(source[pos..], "Requirement.new") orelse return error.InvalidKaiRequirement;
        const id = try parseStringField(allocator, body, "id");
        errdefer allocator.free(id);
        try out.append(.{ .name = try allocator.dupe(u8, name), .id = id });
        cursor = pos + "Requirement.new".len;
    }
    return out.toOwnedSlice();
}

fn parseBindingDefs(allocator: std.mem.Allocator, source: []const u8, requirements: []const RequirementDef) ![]const BindingDef {
    var out = std.array_list.Managed(BindingDef).init(allocator);
    errdefer {
        for (out.items) |binding| binding.deinit(allocator);
        out.deinit();
    }

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "Nix.bind(")) |pos| {
        const open = std.mem.indexOfScalarPos(u8, source, pos, '(') orelse break;
        const close = matchingDelimiter(source, open, '(', ')') orelse return error.InvalidNixBinding;
        const args = source[open + 1 .. close];
        const first_comma = std.mem.indexOfScalar(u8, args, ',') orelse return error.InvalidNixBinding;
        const requirement_name = std.mem.trim(u8, args[0..first_comma], " \t\r\n");
        const requirement_id = requirementIdForName(requirement_name, requirements) orelse {
            cursor = close + 1;
            continue;
        };
        const path_start = std.mem.indexOfScalarPos(u8, args, first_comma + 1, '[') orelse return error.InvalidNixBinding;
        const path_end = matchingDelimiter(args, path_start, '[', ']') orelse return error.InvalidNixBinding;
        const path = try parseStringList(allocator, args[path_start + 1 .. path_end]);
        errdefer {
            for (path) |segment| allocator.free(segment);
            allocator.free(path);
        }
        if (path.len != 0) {
            try out.append(.{ .requirement_id = try allocator.dupe(u8, requirement_id), .path = path });
        } else {
            for (path) |segment| allocator.free(segment);
            allocator.free(path);
        }
        cursor = close + 1;
    }
    return out.toOwnedSlice();
}

fn parseStringList(allocator: std.mem.Allocator, source: []const u8) ![]const []u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |segment| allocator.free(segment);
        out.deinit();
    }
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, cursor, '"')) |open| {
        const close = std.mem.indexOfScalarPos(u8, source, open + 1, '"') orelse return error.InvalidStringList;
        try out.append(try allocator.dupe(u8, source[open + 1 .. close]));
        cursor = close + 1;
    }
    return out.toOwnedSlice();
}

fn parseTargets(allocator: std.mem.Allocator, workspace_body: []const u8) ![]const []u8 {
    const list = findListField(workspace_body, "target_systems") orelse return error.InvalidKaiTargets;
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |target| allocator.free(target);
        out.deinit();
    }

    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n");
        if (item.len == 0) continue;
        const variant = if (std.mem.lastIndexOfScalar(u8, item, '.')) |dot| item[dot + 1 ..] else item;
        const target = targetVariantToString(variant) orelse continue;
        try out.append(try allocator.dupe(u8, target));
    }
    return out.toOwnedSlice();
}

fn parseEnvironments(allocator: std.mem.Allocator, source: []const u8, requirements: []const RequirementDef) ![]const EnvironmentDef {
    var out = std.array_list.Managed(EnvironmentDef).init(allocator);
    errdefer {
        for (out.items) |environment| environment.deinit(allocator);
        out.deinit();
    }

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "Environment.new")) |pos| {
        const body = findCallBody(source[pos..], "Environment.new") orelse return error.InvalidKaiEnvironment;
        const name = try parseStringField(allocator, body, "name");
        errdefer allocator.free(name);
        const requirement_names = findListField(body, "requirements") orelse return error.InvalidKaiEnvironment;
        const ids = try parseEnvironmentRequirementIds(allocator, requirement_names, requirements);
        errdefer {
            for (ids) |id| allocator.free(id);
            allocator.free(ids);
        }
        try out.append(.{ .name = name, .requirements = ids });
        cursor = pos + "Environment.new".len;
    }
    return out.toOwnedSlice();
}

fn parseEnvironmentRequirementIds(allocator: std.mem.Allocator, list: []const u8, requirements: []const RequirementDef) ![]const []u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |id| allocator.free(id);
        out.deinit();
    }

    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0) continue;
        const id = requirementIdForName(name, requirements) orelse return error.UnknownRequirement;
        try out.append(try allocator.dupe(u8, id));
    }
    return out.toOwnedSlice();
}

fn requirementIdForName(name: []const u8, requirements: []const RequirementDef) ?[]const u8 {
    for (requirements) |requirement| {
        if (std.mem.eql(u8, requirement.name, name)) return requirement.id;
    }
    return null;
}

fn renderFallbackFlake(allocator: std.mem.Allocator, workspace: WorkspaceDef, bindings: []const BindingDef) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try appendFmt(&out,
        \\# Generated by roc-blueprint and roc-blueprint-nix. Do not edit.
        \\{{
        \\  "description" = "Development environments for {s}";
        \\  "inputs" = {{
        \\    "nixpkgs" = {{
        \\      "url" = "github:NixOS/nixpkgs/nixos-unstable";
        \\    }};
        \\  }};
        \\  "outputs" = {{ nixpkgs, ... }}:
        \\    {{
        \\      "devShells" = {{
        \\
    , .{workspace.name});

    for (workspace.targets) |target| {
        try appendFmt(&out,
            \\        "{s}" = {{
            \\
        , .{target});
        for (workspace.environments) |environment| {
            try appendFmt(&out,
                \\          "{s}" = nixpkgs."legacyPackages"."{s}"."mkShell" {{
                \\            "packages" = [
                \\
            , .{ environment.name, target });
            for (environment.requirements) |requirement_id| {
                try out.appendSlice("              nixpkgs.\"legacyPackages\".");
                try appendFmt(&out, "\"{s}\"", .{target});
                if (bindingPath(requirement_id, bindings)) |path| {
                    for (path) |segment| {
                        try appendFmt(&out, ".\"{s}\"", .{segment});
                    }
                } else {
                    try appendFmt(&out, ".\"{s}\"", .{requirement_id});
                }
                try out.append('\n');
            }
            try out.appendSlice(
                \\            ];
                \\          };
                \\
            );
        }
        try out.appendSlice(
            \\        };
            \\
        );
    }

    try out.appendSlice(
        \\      };
        \\    };
        \\}
        \\
    );
    return out.toOwnedSlice();
}

fn bindingPath(requirement_id: []const u8, bindings: []const BindingDef) ?[]const []u8 {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.requirement_id, requirement_id)) return binding.path;
    }
    return null;
}

fn findCallBody(source: []const u8, name: []const u8) ?[]const u8 {
    const name_pos = std.mem.indexOf(u8, source, name) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, source, name_pos + name.len, '(') orelse return null;
    const close = matchingDelimiter(source, open, '(', ')') orelse return null;
    return source[open + 1 .. close];
}

fn findListField(source: []const u8, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOf(u8, source, field) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, source, field_pos + field.len, ':') orelse return null;
    const open = std.mem.indexOfScalarPos(u8, source, colon + 1, '[') orelse return null;
    const close = matchingDelimiter(source, open, '[', ']') orelse return null;
    return source[open + 1 .. close];
}

fn parseStringField(allocator: std.mem.Allocator, source: []const u8, field: []const u8) ![]u8 {
    const field_pos = std.mem.indexOf(u8, source, field) orelse return error.MissingStringField;
    const colon = std.mem.indexOfScalarPos(u8, source, field_pos + field.len, ':') orelse return error.MissingStringField;
    const open = std.mem.indexOfScalarPos(u8, source, colon + 1, '"') orelse return error.MissingStringField;
    const close = std.mem.indexOfScalarPos(u8, source, open + 1, '"') orelse return error.MissingStringField;
    return allocator.dupe(u8, source[open + 1 .. close]);
}

fn matchingDelimiter(source: []const u8, open: usize, comptime open_ch: u8, comptime close_ch: u8) ?usize {
    var depth: usize = 0;
    var cursor = open;
    while (cursor < source.len) : (cursor += 1) {
        const ch = source[cursor];
        if (ch == '"') {
            cursor += 1;
            while (cursor < source.len and source[cursor] != '"') : (cursor += 1) {}
        } else if (ch == open_ch) {
            depth += 1;
        } else if (ch == close_ch) {
            depth -= 1;
            if (depth == 0) return cursor;
        }
    }
    return null;
}

fn appendFmt(out: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(out.allocator, fmt, args);
    defer out.allocator.free(text);
    try out.appendSlice(text);
}

fn targetVariantToString(variant: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, variant, "X86_64Linux")) return "x86_64-linux";
    if (std.mem.eql(u8, variant, "Aarch64Darwin")) return "aarch64-darwin";
    return null;
}

fn runNixDevelop(io: std.Io, target: []const u8) !u8 {
    const argv = nixDevelopArgv(target);
    return runProcessStatus(io, &argv);
}

fn nixDevelopArgv(target: []const u8) [4][]const u8 {
    return .{ "nix", "develop", "--no-write-lock-file", target };
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
    try std.testing.expectEqual(HelpTopic.shell, (try parseCommand(&.{ "shell", "--help" })).help);
    try std.testing.expectEqual(HelpTopic.zen, (try parseCommand(&.{ "help", "zen" })).help);
    try std.testing.expectEqual(HelpTopic.zen, (try parseCommand(&.{ "zen", "--help" })).help);
    try std.testing.expectEqual(Command.zen, try parseCommand(&.{"zen"}));

    const shell_default = try parseCommand(&.{"shell"});
    try std.testing.expectEqualStrings("shell", shell_default.shell.cli_name);
    try std.testing.expectEqualStrings(default_config_file, shell_default.shell.path);
    const shell_file = try parseCommand(&.{ "sh", "examples/hello-shell/main.roc" });
    try std.testing.expectEqualStrings("examples/hello-shell/main.roc", shell_file.shell.path);

    const init = try parseCommand(&.{ "shell", "init", "my-app", "--force" });
    try std.testing.expectEqualStrings("my-app", init.shell_init.directory);
    try std.testing.expect(init.shell_init.force);
}

test "rejects invalid command usage" {
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "shell", "a", "b" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "shell", "init", "one", "two" }));
    try std.testing.expectError(error.InvalidCommand, parseCommand(&.{ "zen", "one" }));
}

test "preserves unavailable command name" {
    const command = try parseCommand(&.{"deploy"});
    try std.testing.expectEqualStrings("deploy", command.unavailable);
}

test "strips package header for generated nix wrapper" {
    const source =
        \\package [workspace] {
        \\    blueprint: "url",
        \\}
        \\
        \\import blueprint.Blueprint
        \\workspace = Blueprint.workspace({ name: "demo", target_systems: [], envs: [] })
        \\
    ;
    const body = stripPackageHeader(source) orelse return error.ExpectedPackageBody;
    try std.testing.expect(std.mem.startsWith(u8, body, "import blueprint.Blueprint"));
    try std.testing.expect(stripPackageHeader("app [main!] {}") == null);
}

test "skips Roc header trivia" {
    try std.testing.expectEqual(@as(usize, 0), skipRocHeaderTrivia("package [workspace] {}"));
    try std.testing.expect(skipRocHeaderTrivia("# comment\npackage [workspace] {}") > 0);
}

test "default nix bindings document generated convention" {
    try std.testing.expect(std.mem.indexOf(u8, default_nix_bindings_source, "requirement id == nixpkgs package attribute") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_nix_bindings_source, "Nix.bind(requirement, \"nixpkgs\", [Requirement.id(requirement)])") != null);
}

test "fallback renderer renders package-style blueprint workspace" {
    const source =
        \\package [workspace] { blueprint: "url" }
        \\import blueprint.Blueprint
        \\import blueprint.Environment
        \\import blueprint.Requirement
        \\import blueprint.Target
        \\
        \\hello : Requirement
        \\hello = Requirement.new({ id: "hello", display_name: "Hello" })
        \\
        \\workspace : Blueprint.Draft
        \\workspace = Blueprint.workspace({
        \\    name: "hello-shell",
        \\    target_systems: [Target.X86_64Linux, Target.Aarch64Linux, Target.X86_64Darwin, Target.Aarch64Darwin],
        \\    envs: [Environment.new({ name: "default", requirements: [hello] })],
        \\})
        \\
    ;
    var workspace = try parseWorkspaceSource(std.testing.allocator, source);
    defer workspace.deinit(std.testing.allocator);

    const flake = try renderFallbackFlake(std.testing.allocator, workspace, &[_]BindingDef{});
    defer std.testing.allocator.free(flake);

    const expected =
        \\# Generated by roc-blueprint and roc-blueprint-nix. Do not edit.
        \\{
        \\  "description" = "Development environments for hello-shell";
        \\  "inputs" = {
        \\    "nixpkgs" = {
        \\      "url" = "github:NixOS/nixpkgs/nixos-unstable";
        \\    };
        \\  };
        \\  "outputs" = { nixpkgs, ... }:
        \\    {
        \\      "devShells" = {
        \\        "x86_64-linux" = {
        \\          "default" = nixpkgs."legacyPackages"."x86_64-linux"."mkShell" {
        \\            "packages" = [
        \\              nixpkgs."legacyPackages"."x86_64-linux"."hello"
        \\            ];
        \\          };
        \\        };
        \\        "aarch64-darwin" = {
        \\          "default" = nixpkgs."legacyPackages"."aarch64-darwin"."mkShell" {
        \\            "packages" = [
        \\              nixpkgs."legacyPackages"."aarch64-darwin"."hello"
        \\            ];
        \\          };
        \\        };
        \\      };
        \\    };
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, flake);
}

test "builds nix develop argv" {
    const argv = nixDevelopArgv("path:.kai/shell#default");
    try std.testing.expectEqualStrings("nix", argv[0]);
    try std.testing.expectEqualStrings("develop", argv[1]);
    try std.testing.expectEqualStrings("--no-write-lock-file", argv[2]);
    try std.testing.expectEqualStrings("path:.kai/shell#default", argv[3]);
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
