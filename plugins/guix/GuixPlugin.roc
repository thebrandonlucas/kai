import kai.Plugin
import backends.Guix as GuixBackend
import commands.Shell as ShellCommand
import implementations.ShellGuix

GuixPlugin := [].{
	plugin : Plugin.Definition
	plugin = Plugin.Definition.{
		commands,
		backends,
		implementations,
		name,
		project_configs,
	}

	name = "guix"

	project_configs : List(Plugin.ProjectConfigDescriptor)
	project_configs = []

	commands : List(Plugin.Command)
	commands = [ShellCommand.command]

	backends : List(Plugin.Backend)
	backends = [GuixBackend.backend]

	implementations : List(Plugin.Implementation)
	implementations = [ShellGuix.implementation]
}
