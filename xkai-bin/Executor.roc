import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Stdout

import kai.Plugin as PluginApi

# Generic effect boundary for pure plugin plans.
Executor := [].{
	run! : PluginApi.Plugin, List(OsStr) => Try({}, _)
	run! = |plugin, args| {
		display_args = args.drop_first(1).map(OsStr.display)

		match display_args {
			[] => {
				# Dump all concat'd command names as a naive placeholder help
				command_names = plugin.commands.map(|command| command.name)
				Stdout.line!("usage: kai ${Str.join_with(command_names, "|")}")
			}
			[command_name, ..] =>
				match PluginApi.find_implementation(plugin, command_name) {
					Err(_) => Stdout.line!("Unknown command ${command_name}")
					Ok(implementation) => Executor.run_implementation!(implementation)
				}
			}
	}

	run_implementation! : PluginApi.Implementation => Try({}, _)
	run_implementation! = |implementation| {
		output = Cmd.new(OsStr.utf8("roc"))
			.args([OsStr.utf8(implementation.config_program)])
			.exec_output!()?

		plan : PluginApi.Plan
		plan = Json.parse(output.stdout_utf8) ? |err| InvalidPlan(err)

		Executor.execute!(plan)
	}

	execute! : PluginApi.Plan => Try({}, _)
	execute! = |plan| {
		for action in plan.actions {
			Executor.execute_action!(action)?
		}
		Ok({})
	}

	# Generically execute side-effects as defined by the plugin 
	# Currently, only writing (e.g. flake.nix) or running commands 
	# (e.g. "nix shell")

	# This keeps plugin models & testing pure and effect-free
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
