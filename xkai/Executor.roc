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
				first.commands
					.map(|selection| "  ${selection.command.name}")
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
				"More information: https://github.com/thebrandonlucas/kai",
			]),
			"\n",
		)

	Invocation := { args : List(Str), kaifile : Str }

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
							config_text = Path.read_utf8!(Path.utf8(invocation.kaifile))?
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
								config_text,
								invocation.args,
								host_os,
								host.arch,
							) {
								Ok(selected_plan) => Executor.execute!(selected_plan)
								Err(PlanningFailed(diagnostic)) => Err(PlanningFailed(diagnostic))
								Err(UnknownCommand) => Err(UnknownCommand)
							}
						}
					}
				}
		}
	}

	execute! : Plugin.Plan => Try({}, _)
	execute! = |execution_plan| {
		for action in execution_plan.actions {
			Executor.execute_action!(action)?
		}
		Ok({})
	}

	execute_action! : Plugin.Action => Try({}, _)
	execute_action! = |action|
		match action {
			PrintLine(line) => Stdout.line!(line)
			WriteUtf8({ content, path }) => {
				parent_parts = Str.split_on(path, "/").drop_last(1)
				if !parent_parts.is_empty() {
					Path.create_all!(Path.utf8(Str.join_with(parent_parts, "/")))?
				}
				Path.write_utf8!(Path.utf8(path), content)?
				Stdout.line!("wrote: ${path}")
			}
			Exec({ args, command }) =>
				Cmd.exec!(OsStr.utf8(command), args.map(OsStr.utf8))
			}
}
