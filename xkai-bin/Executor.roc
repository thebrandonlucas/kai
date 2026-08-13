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

	run! : List(OsStr), List(PluginApi.RegistryDefinition) => Try({}, _)
	run! = |args, registry| {
		display_args = args.drop_first(1).map(OsStr.display)
		match display_args {
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
				config_text = Path.read_utf8!(Path.utf8("Kaifile"))?
				host = Env.platform!()
				host_os : PluginApi.HostOs
				host_os = match host.os {
					LINUX => LINUX
					MACOS => MACOS
					OTHER(name) => OTHER(name)
					_ => OTHER("unsupported")
				}
				match PluginApi.plan_registry(registry, config_text, display_args, host_os, host.arch) {
					Ok(selected_plan) => Executor.execute!(selected_plan)
					Err(PlanningFailed(diagnostic)) => Err(PlanningFailed(diagnostic))
					Err(UnknownCommand) => Err(UnknownCommand)
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
