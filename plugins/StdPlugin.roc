import kai.Plugin as PluginApi
import backends.Nix as NixBackend
import commands.Shell as ShellCommand
import implementations.ShellNix

StdPlugin := [].{
	plugin : PluginApi.RegistryDefinition
	plugin = {
		definition,
		select_config: PluginApi.select_config,
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
