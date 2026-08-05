# Generically execute side-effects as defined by the plugin 
# Currently, only writing (e.g. flake.nix) or running commands 
# (e.g. "nix shell")

# This keeps plugin models & testing pure and effect-free

import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Stdout

import kai.Plugin as PluginApi

import "VERSION" as canonical_version : Str

Executor := [].{
	version : Str
	version = canonical_version

	run! : List(OsStr) => Try({}, _)
	run! = |args|
		match args.drop_first(1).map(OsStr.display) {
			["version"] => {
				Stdout.line!("kai version ${Executor.version}")?
				Ok({})
			}
			_ => {
				config_args = [OsStr.utf8("kai.roc")].concat(args.drop_first(1))
				output = Cmd.new(OsStr.utf8("roc"))
					.args(config_args)
					.exec_output!()?

				plan : PluginApi.Plan
				plan = Json.parse(output.stdout_utf8) ? |err| InvalidPlan(err)

				Executor.execute!(plan)
			}
		}

	execute! : PluginApi.Plan => Try({}, _)
	execute! = |plan| {
		for action in plan.actions {
			Executor.execute_action!(action)?
		}
		Ok({})
	}

	execute_action! : PluginApi.Action => Try({}, _)
	execute_action! = |action|
		match action {
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
