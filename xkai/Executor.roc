# Generically execute side-effects as defined by the plugin.
# This keeps plugin models & testing pure and effect-free.

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

import kai.Plugin

import "VERSION" as canonical_version : Str

Executor := [].{
	version : Str
	version = canonical_version

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

	command_lines : List(Plugin.Definition) -> List(Str)
	command_lines = |registry|
		match registry {
			[] => []
			[first, .. as rest] =>
				first.schema.commands
					.map(
						|command|
							"  ${Plugin.syntax_from_command(command).name}",
					)
					.concat(Executor.command_lines(rest))
			}

	help : List(Plugin.Definition) -> Str
	help = |registry|
		Str.join_with(
			[
				"Kai makes reproducible systems easy, friendly, and fun.",
				"",
				"Usage:",
				"  kai [OPTIONS] <COMMAND> [ARGUMENTS]",
				"",
				"Commands:",
			].concat(Executor.command_lines(registry)).concat([
				"  version",
				"",
				"Options:",
				"  -f, --file <PATH>  Use the Kaifile at PATH",
				"  -h, --help         Print help",
				"",
				"Environment:",
				"  KAI_DIR             Project-local workspace directory (default: .kai)",
				"",
				"More information: https://github.com/thebrandonlucas/kai",
			]),
			"\n",
		)

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
		if Executor.help_requested(display_args) {
			Stdout.line!(Executor.help(registry))?
			Ok({})
		} else {
			match Executor.parse_invocation(display_args) {
				Err(MissingKaifilePath) => Err(MissingKaifilePath)
				Ok(invocation) =>
					match invocation.args {
						["--xkai-validate-registry"] =>
							match Plugin.validate_registry(registry) {
								Ok({}) => Ok({})
								Err(diagnostic) => Err(InvalidRegistry(diagnostic))
							}
						["version"] => {
							Stdout.line!("kai version ${Executor.version}")?
							Ok({})
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
									Executor.execute!(selected_plan, workspace_root)
								}
								Err(InvalidWorkspaceRoot(message)) => Err(InvalidWorkspaceRoot(message))
								Err(PlanningFailed(diagnostic)) => Err(PlanningFailed(diagnostic))
								Err(UnknownCommand) => Err(UnknownCommand)
							}
						}
					}
				}
		}
	}

	execute! : Plugin.ExecutionPlan, Str => Try({}, _)
	execute! = |execution_plan, workspace_root| {
		for step in execution_plan.steps {
			Executor.execute_step!(step, workspace_root)?
		}
		Ok({})
	}

	execute_step! : Plugin.ExecutionStep, Str => Try({}, _)
	execute_step! = |step, workspace_root|
		match step {
			PrintLine(line) => Stdout.line!(line)
			WriteFile({ contents, path }) => {
				# TODO: Use descriptor-relative no-follow writes when basic-cli
				# exposes them.
				Executor.ensure_workspace_path_safe!(workspace_root, path)?
				parent_parts = Str.split_on(path, "/").drop_last(1)
				if !parent_parts.is_empty() {
					Path.create_all!(Path.utf8(Str.join_with(parent_parts, "/")))?
				}
				Path.write_utf8!(Path.utf8(path), contents)?
				Stdout.line!("wrote: ${path}")
			}
			RunProgram({ arguments, program }) =>
				Cmd.exec!(OsStr.utf8(program), arguments.map(OsStr.utf8))
			}
}
