# Generically execute side-effects as defined by the plugin.
# This keeps plugin models & testing pure and effect-free.

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

import kai.Plugin as PluginApi

import "VERSION" as canonical_version : Str

Executor := [].{
	version : Str
	version = canonical_version

	Invocation := { args : List(Str), kaifile : Str }

	parse_invocation : List(Str) -> Try(Invocation, [MissingKaifilePath])
	parse_invocation = |args|
		match args {
			["-f"] => Err(MissingKaifilePath)
			["--file"] => Err(MissingKaifilePath)
			["-f", kaifile, .. as command_args] => Ok({ args: command_args, kaifile })
			["--file", kaifile, .. as command_args] => Ok({ args: command_args, kaifile })
			_ => Ok({ args, kaifile: "Kaifile" })
		}

	run! : List(OsStr), List(PluginApi.RegistryDefinition) => Try({}, _)
	run! = |args, registry| {
		display_args = args.drop_first(1).map(OsStr.display)
		match Executor.parse_invocation(display_args) {
			Err(MissingKaifilePath) => Err(MissingKaifilePath)
			Ok(invocation) =>
				match invocation.args {
					["--xkai-validate-registry"] =>
						match PluginApi.validate_registry(registry) {
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
						host_os : PluginApi.HostOs
						host_os = match host.os {
							LINUX => LINUX
							MACOS => MACOS
							OTHER(name) => OTHER(name)
							_ => OTHER("unsupported")
						}
						match PluginApi.plan_registry(registry, config_text, invocation.args, host_os, host.arch) {
							Ok(selected_plan) => Executor.execute!(selected_plan)
							Err(PlanningFailed(diagnostic)) => Err(PlanningFailed(diagnostic))
							Err(UnknownCommand) => Err(UnknownCommand)
						}
					}
				}
			}
	}

	execute! : PluginApi.Plan => Try({}, _)
	execute! = |execution_plan| {
		for action in execution_plan.actions {
			Executor.execute_action!(action)?
		}
		Ok({})
	}

	execute_action! : PluginApi.Action => Try({}, _)
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

# -- TESTS --

parse_invocation_cases = [
	{
		args: ["shell"],
		expected: Ok({ args: ["shell"], kaifile: "Kaifile" }),
	},
	{
		args: ["-f", "../shared/Kaifile", "shell"],
		expected: Ok({ args: ["shell"], kaifile: "../shared/Kaifile" }),
	},
	{
		args: ["--file", "/tmp/Kaifile", "run", "moo"],
		expected: Ok({ args: ["run", "moo"], kaifile: "/tmp/Kaifile" }),
	},
	{
		args: ["shell", "-f", "plugin-value"],
		expected: Ok({ args: ["shell", "-f", "plugin-value"], kaifile: "Kaifile" }),
	},
]

expect List.all(
	parse_invocation_cases,
	|case| Executor.parse_invocation(case.args) == case.expected,
)

expect Executor.parse_invocation(["-f"]) == Err(MissingKaifilePath)
expect Executor.parse_invocation(["--file"]) == Err(MissingKaifilePath)
