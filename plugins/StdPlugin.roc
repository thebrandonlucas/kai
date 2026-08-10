import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Shell as ShellCommand
import implementations.ShellNix

StdPlugin := [].{
	plugin : PluginApi.Plugin
	plugin = PluginApi.Plugin.Module({
		definition,
		plan: StdPlugin.plan,
	})

	plan :
		Str,
		List(Str),
		PluginApi.HostOs,
		PluginApi.HostArch ->
			Try(
				PluginApi.Plan,
				PluginApi.Error,
			)
	plan = |config_text, args, os, arch|
		match args {
			["shell"] => ShellNix.plan(definition.name, config_text, os, arch)
			_ => Err(UnknownCommand)
		}

	commands : List(PluginApi.Command)
	commands = [ShellCommand.command]

	backends : List(PluginApi.Backend)
	backends = [NixBackend.backend]

	implementations : List(PluginApi.Implementation)
	implementations = [ShellNix.implementation]

	definition : PluginApi.Definition
	definition = PluginApi.Definition.{
		backends,
		commands,
		implementations,
		name: "std",
	}
}
