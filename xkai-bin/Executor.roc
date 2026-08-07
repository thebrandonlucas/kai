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

	run! : List(OsStr), List(PluginApi.Plugin) => Try({}, _)
	run! = |args, registry| {
		display_args = args.drop_first(1).map(OsStr.display)
		match display_args {
			["version"] => {
				Stdout.line!("kai version ${Executor.version}")?
				Ok({})
			}
			_ => {
				source = Path.read_utf8!(Path.utf8("config.kai"))?
				host = Env.platform!()
				host_os : PluginApi.HostOs
				host_os = match host.os {
					LINUX => LINUX
					MACOS => MACOS
					OTHER(name) => OTHER(name)
					_ => OTHER("unsupported")
				}
				match Executor.dispatch(registry, source, display_args, host_os, host.arch) {
					Ok(selected_plan) => Executor.execute!(selected_plan)
					Err(InvalidConfig) => Err(InvalidConfig)
					Err(UnknownCommand) => Err(UnknownCommand)
					Err(UnsupportedPlatform) => Err(UnsupportedPlatform)
				}
			}
		}
	}

	dispatch : List(PluginApi.Plugin), Str, List(Str), PluginApi.HostOs, PluginApi.HostArch -> Try(PluginApi.Plan, PluginApi.Error)
	dispatch = |registry, source, args, os, arch|
		match registry {
			[] => Err(UnknownCommand)
			[first, .. as rest] =>
				match PluginApi.run(first, source, args, os, arch) {
					Err(UnknownCommand) => Executor.dispatch(rest, source, args, os, arch)
					result => result
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
