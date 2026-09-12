# Generically execute side-effects as defined by the plugin.
# This keeps plugin models & testing pure and effect-free.

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout

import kai.PlanningError
import kai.Plugin

import "VERSION" as canonical_version : Str

Executor := [].{
	version : Str
	version = canonical_version

	json_line! = |kind, fields|
		Stdout.line!("{\"type\":${Json.to_str(kind)}${fields}}")

	output! = |json, kind, message|
		if json {
			Executor.json_line!(kind, ",\"message\":${Json.to_str(message)}")
		} else {
			Stdout.line!(message)
		}

	json_error! = |name, message, extra| {
		name_json = Json.to_str(name)
		message_json = Json.to_str(message)
		fields = ",\"error\":${name_json},\"message\":${message_json}${extra}"
		Executor.json_line!("error", fields)
	}

	help_requested : List(Str) -> Bool
	help_requested = |args|
		List.any(args, |arg| arg == "-h" or arg == "--help") or
			match args {
				[] => Bool.True
				["help", ..] => Bool.True
				["-f", _, .. as command_args] => Executor.help_requested(command_args)
				["--file", _, .. as command_args] => Executor.help_requested(command_args)
				_ => Bool.False
			}

	HelpCommand : [CommandHelpRequested(Str), NoCommandHelpRequested]

	requested_help_command : List(Str) -> HelpCommand
	requested_help_command = |args|
		match args {
			["-f", _, .. as command_args] | ["--file", _, .. as command_args] =>
				Executor.requested_help_command(command_args)
			["help", command, ..] => CommandHelpRequested(command)
			[command, .. as command_args] =>
				if List.any(command_args, |arg| arg == "-h" or arg == "--help") {
					CommandHelpRequested(command)
				} else {
					NoCommandHelpRequested
				}
			_ => NoCommandHelpRequested
		}

	argument_usage : List(Plugin.CommandHelpArgument) -> Str
	argument_usage = |arguments|
		match arguments {
			[] => ""
			[first, .. as rest] => {
				argument = match first.presence {
					OptionalHelpArgument => " [${first.name}]"
					RequiredHelpArgument => " <${first.name}>"
				}
				"${argument}${Executor.argument_usage(rest)}"
			}
		}

	argument_lines : List(Plugin.CommandHelpArgument) -> List(Str)
	argument_lines = |arguments|
		arguments.map(|argument| "  ${argument.name}  ${argument.description}")

	kaifile_block_example_lines : Plugin.CommandHelp -> List(Str)
	kaifile_block_example_lines = |help_content|
		match help_content.kaifile_block_example {
			KaifileBlockExample(lines) =>
				["", "Kaifile block:"].concat(lines.map(|line| "  ${line}"))
			NoKaifileBlockExample => []
		}

	render_command_help : Plugin.CommandSyntax, Plugin.CommandHelp -> Str
	render_command_help = |command, help_content| {
		usage_arguments = Executor.argument_usage(help_content.arguments)
		usage = "  kai [OPTIONS] ${command.name} [BACKEND]${usage_arguments} [--json]"
		Str.join_with(
			[
				help_content.description,
				"",
				"Usage:",
				usage,
				"",
				"Examples:",
			].concat(help_content.examples.map(|example| "  ${example}")).concat(
				Executor.kaifile_block_example_lines(help_content),
			).concat([
				"",
				"Arguments:",
				"  BACKEND  Optional backend name",
			]).concat(Executor.argument_lines(help_content.arguments)).concat([
				"",
				"Options:",
				"  -f, --file <PATH>  Use the Kaifile at PATH",
				"      --json         Output JSON Lines",
				"  -h, --help         Print help",
			]),
			"\n",
		)
	}

	command_help_for : List(Plugin.Definition), Str -> [None, Some(Str)]
	command_help_for = |registry, name|
		match Plugin.find_owner(registry, name) {
			Err(UnknownCommand) => None
			Ok(owner) => {
				command = Plugin.syntax_from_command(owner.command)
				match command.help {
					CommandHelpAvailable(help_content) => Some(
						Executor.render_command_help(command, help_content),
					)
					NoCommandHelp => None
				}
			}
		}

	CommandLine := { description : Str, name : Str }

	command_rows : List(Plugin.Definition) -> List(CommandLine)
	command_rows = |registry|
		match registry {
			[] => []
			[first, .. as rest] =>
				first.schema.commands
					.map(
						|command| {
							syntax = Plugin.syntax_from_command(command)
							description = match syntax.help {
								CommandHelpAvailable(help_content) => help_content.description
								NoCommandHelp => ""
							}
							{ description, name: syntax.name }
						},
					)
					.concat(Executor.command_rows(rest))
			}

	longest_command_name : List(CommandLine) -> U64
	longest_command_name = |commands|
		match commands {
			[] => 0
			[first, .. as rest] => {
				first_width = first.name.to_utf8().len()
				rest_width = Executor.longest_command_name(rest)
				if first_width > rest_width first_width else rest_width
			}
		}

	command_lines : List(CommandLine), U64 -> List(Str)
	command_lines = |commands, width|
		commands.map(
			|command|
				if command.description.is_empty() {
					"  ${command.name}"
				} else {
					padding = " ".repeat(width - command.name.to_utf8().len() + 2)
					"  ${command.name}${padding}${command.description}"
				},
		)

	help : List(Plugin.Definition) -> Str
	help = |registry| {
		commands = Executor.command_rows(registry).concat([
			{ description: "Print version information.", name: "version" },
		])
		Str.join_with(
			[
				"A friendly frontend for determinate computing",
				"",
				"Usage:",
				"  kai [OPTIONS] <COMMAND> [ARGUMENTS] [--json]",
				"",
				"Kai is a tool for providing a simplified interface on top of determinate",
				"systems (mainly Nix) for ease of use. Commands often correspond with a",
				"Kaifile block defining their behavior:",
				"",
				"  $ kai shell",
				"  $ cowsay \"Hello from Kai!\"",
				"",
				"  # Kaifile",
				"  shell {",
				"      packages: [\"cowsay\"]",
				"  }",
				"",
				"Commands:",
			].concat(
				Executor.command_lines(commands, Executor.longest_command_name(commands)),
			).concat([
				"",
				"Options:",
				"  -f, --file <PATH>  Use the Kaifile at PATH",
				"      --json         Output JSON Lines",
				"  -h, --help         Print help",
				"",
				"Environment:",
				"  KAI_DIR             Project-local workspace directory (default: .kai)",
				"",
				"More information: https://github.com/thebrandonlucas/kai",
			]),
			"\n",
		)
	}

	Invocation := { args : List(Str), kaifile : Str }

	workspace_root! : () => Try(Str, _)
	workspace_root! = ||
		match Env.var_str!(OsStr.utf8("KAI_DIR")) {
			Ok(workspace_root) => Ok(workspace_root)
			Err(VarNotFound(_)) => Ok(Plugin.default_workspace_root)
			Err(problem) => Err(problem)
		}

	workspace_marker_name = ".kai-workspace"
	workspace_marker_contents = "Kai project workspace\n"

	prepare_workspace! : Str => Try({}, _)
	prepare_workspace! = |workspace_root| {
		root_path = Path.utf8(workspace_root)
		if Path.is_sym_link!(root_path)? {
			Err(UnsafeWorkspaceRoot("workspace root must not be a symbolic link"))
		} else if workspace_root == Plugin.default_workspace_root {
			if Path.exists!(root_path)? and !Path.is_dir!(root_path)? {
				Err(UnsafeWorkspaceRoot("workspace root must be a directory"))
			} else {
				Ok({})
			}
		} else if Path.exists!(root_path)? {
			marker = Path.join(root_path, Executor.workspace_marker_name)
			if !Path.is_dir!(root_path)? {
				Err(UnsafeWorkspaceRoot("workspace root must be a directory"))
			} else if !Path.is_file!(marker)? {
				Err(
					UnsafeWorkspaceRoot(
						"existing custom workspace root is not owned by Kai",
					),
				)
			} else if Path.read_utf8!(marker)? != Executor.workspace_marker_contents {
				Err(
					UnsafeWorkspaceRoot(
						"custom workspace root has an invalid ownership marker",
					),
				)
			} else {
				Ok({})
			}
		} else {
			Path.create_dir!(root_path)?
			marker = Path.join(root_path, Executor.workspace_marker_name)
			marker_result = Path.write_utf8!(
				marker,
				Executor.workspace_marker_contents,
			)
			match marker_result {
				Ok({}) => Ok({})
				Err(problem) => {
					Path.delete!(marker) ?? {}
					Path.delete_empty!(root_path) ?? {}
					Err(problem)
				}
			}
		}
	}

	ensure_workspace_path_safe! : Str, Str => Try({}, _)
	ensure_workspace_path_safe! = |workspace_root, path|
		if path == workspace_root or path.starts_with("${workspace_root}/") {
			Executor.ensure_path_parts_safe!(path.split_on("/"), "")
		} else {
			Ok({})
		}

	ensure_path_parts_safe! : List(Str), Str => Try({}, _)
	ensure_path_parts_safe! = |parts, parent|
		match parts {
			[] => Ok({})
			[first, .. as rest] => {
				path = if parent.is_empty() {
					first
				} else {
					"${parent}/${first}"
				}
				if Path.is_sym_link!(Path.utf8(path))? {
					Err(
						UnsafeWorkspaceRoot(
							"workspace write path must not contain symbolic links",
						),
					)
				} else {
					Executor.ensure_path_parts_safe!(rest, path)
				}
			}
		}

	parse_invocation : List(Str) -> Try(Invocation, [MissingKaifilePath])
	parse_invocation = |args|
		match args {
			["-f"] => Err(MissingKaifilePath)
			["--file"] => Err(MissingKaifilePath)
			["-f", kaifile, .. as command_args] => Ok({ args: command_args, kaifile })
			["--file", kaifile, .. as command_args] => Ok({
				args: command_args,
				kaifile,
			})
			_ => Ok({ args, kaifile: "Kaifile" })
		}

	run! : List(OsStr), List(Plugin.Definition) => Try({}, _)
	run! = |args, registry| {
		display_args = args.drop_first(1).map(OsStr.display)
		json = display_args.contains("--json")
		clean_args = display_args.keep_if(|arg| arg != "--json")
		match Executor.run_mode!(clean_args, registry, json) {
			Err(Exit(code)) => Err(Exit(code))
			Err(problem) if json => {
				Executor.json_error!("kai_failed", Str.inspect(problem), "")?
				Err(Exit(1))
			}
			result => result
		}
	}

	run_mode! = |display_args, registry, json| {
		requested_help = match Executor.requested_help_command(display_args) {
			CommandHelpRequested(command) => Executor.command_help_for(registry, command)
			NoCommandHelpRequested => None
		}
		match requested_help {
			Some(help_text) => Executor.output!(json, "help", help_text)
			None if Executor.help_requested(display_args) =>
				Executor.output!(json, "help", Executor.help(registry))
			None =>
				match Executor.parse_invocation(display_args) {
					Err(MissingKaifilePath) => Err(MissingKaifilePath)
					Ok(invocation) =>
						match invocation.args {
							["--xkai-validate-registry"] =>
								match Plugin.validate_registry(registry) {
									Ok({}) => Ok({})
									Err(diagnostic) => Err(InvalidRegistry(diagnostic))
								}
							["version"] =>
								if json {
									Executor.json_line!(
										"version",
										",\"version\":${Json.to_str(Executor.version)}",
									)
								} else {
									Stdout.line!("kai version ${Executor.version}")
								}
							_ => {
								kaifile_text = Path.read_utf8!(Path.utf8(invocation.kaifile))?
								workspace_root = Executor.workspace_root!()?
								host = Env.platform!()
								host_os : Plugin.HostOs
								host_os = match host.os {
									LINUX => LINUX
									MACOS => MACOS
									OTHER(name) => OTHER(name)
									_ => OTHER("unsupported")
								}
								match Plugin.plan_registry(
									registry,
									kaifile_text,
									invocation.args,
									host_os,
									host.arch,
									workspace_root,
								) {
									Ok(selected_plan) => {
										Executor.prepare_workspace!(workspace_root)?
										Executor.execute!(selected_plan, workspace_root, json)
									}
									Err(InvalidWorkspaceRoot(message)) =>
										Err(InvalidWorkspaceRoot(message))
									Err(PlanningFailed(diagnostic)) => {
										if json {
											extra = ",\"command\":${
												Json.to_str(
													diagnostic.command,
												)
											}"
											Executor.json_error!(
												"planning_failed",
												diagnostic.message,
												extra,
											)?
										} else {
											Stderr.line!(
												PlanningError.planning_error(
													invocation.kaifile,
													kaifile_text,
													registry,
													diagnostic,
												),
											)?
										}
										Err(Exit(1))
									}
									Err(UnknownCommand) => Err(UnknownCommand)
								}
							}
						}
					}
			}
	}

	execute! : Plugin.ExecutionPlan, Str, Bool => Try({}, _)
	execute! = |execution_plan, workspace_root, json| {
		for step in execution_plan.steps {
			Executor.execute_step!(step, workspace_root, json)?
		}
		Ok({})
	}

	execute_step! : Plugin.ExecutionStep, Str, Bool => Try({}, _)
	execute_step! = |step, workspace_root, json|
		match step {
			PrintLine(line) => Executor.output!(json, "output", line)
			WriteFile({ contents, path }) => {
				# TODO: Use descriptor-relative no-follow writes when basic-cli
				# exposes them.
				Executor.ensure_workspace_path_safe!(workspace_root, path)?
				parent_parts = Str.split_on(path, "/").drop_last(1)
				if !parent_parts.is_empty() {
					Path.create_all!(Path.utf8(Str.join_with(parent_parts, "/")))?
				}
				Path.write_utf8!(Path.utf8(path), contents)?
				Executor.output!(json, "progress", "wrote: ${path}")
			}
			RunProgram({ arguments, program }) =>
				Executor.run_program!(json, program, arguments)
			}

	emit_process! = |output| {
		for (kind, bytes) in [
			("subprocess_stdout", output.stdout_bytes),
			("subprocess_stderr", output.stderr_bytes),
		] {
			if !bytes.is_empty() {
				Executor.output!(Bool.True, kind, Str.from_utf8_lossy(bytes))?
			}
		}
		Ok({})
	}

	last_nix_error : List(Str), Str -> Str
	last_nix_error = |lines, found|
		match lines {
			[] => found
			[line, .. as rest] => {
				trimmed = line.trim()
				next = if trimmed.starts_with("error:") and trimmed != "error:" {
					trimmed
				} else {
					found
				}
				Executor.last_nix_error(rest, next)
			}
		}

	nix_root_error : Str -> Str
	nix_root_error = |stderr| {
		root = Executor.last_nix_error(stderr.split_on("\n"), "")
		message = Str.from_utf8_lossy(root.to_utf8().drop_first(6)).trim()
		if root.is_empty() {
			"error: Nix command failed"
		} else {
			"error: Nix reported: ${message}"
		}
	}

	emit_human_process! = |output| {
		Stdout.write_bytes!(output.stdout_bytes)?
		Stderr.write_bytes!(output.stderr_bytes)
	}

	run_nix! = |command|
		match command.exec_output_bytes!() {
			Ok(output) => Executor.emit_human_process!(output)
			Err(NonZeroExitCodeB({ exit_code, stderr_bytes, .. })) => {
				Stderr.line!(
					Executor.nix_root_error(Str.from_utf8_lossy(stderr_bytes)),
				)?
				Err(Exit(exit_code))
			}
			Err(problem) => Err(problem)
		}

	run_program! = |json, program, arguments| {
		command = Cmd.new_str(program).args_str(arguments)
		if json {
			match command.exec_output_bytes!() {
				Ok(output) => Executor.emit_process!(output)
				Err(NonZeroExitCodeB({ exit_code, .. } as output)) => {
					Executor.emit_process!(output)?
					extra = ",\"exit_code\":${I32.to_str(exit_code)}"
					Executor.json_error!(
						"subprocess_failed",
						"${program} failed",
						extra,
					)?
					Err(Exit(exit_code))
				}
				Err(problem) => Err(problem)
			}
		} else if program == "nix" and (arguments.first() ?? "") != "develop" {
			Executor.run_nix!(command)
		} else {
			exit_code = command.exec_exit_code!()?
			if exit_code == 0 Ok({}) else Err(Exit(exit_code))
		}
	}
}
