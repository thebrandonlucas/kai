import kai.Plugin as PluginApi

# Minimal plugin package outside the built-in plugins directory.
ExternalPlugin := [].{
	Config : { content : Str }

	file : PluginApi.Backend
	file = PluginApi.Backend.{ name: "file" }

	write_command : PluginApi.Command
	write_command = PluginApi.Command.{
		argv: [],
		backends: [file],
		name: "external-write",
	}

	write_implementation : PluginApi.Implementation
	write_implementation = PluginApi.Implementation.{
		actions: [
			WriteConfigUtf8({
				path: "external-plugin-output.txt",
			}),
		],
		backend: file,
		command: write_command,
		requirement: None,
	}

	write : Config -> {
		implementation : PluginApi.Implementation,
		rendered_config : Str,
	}
	write = |config| {
		implementation: write_implementation,
		rendered_config: config.content,
	}
}

expect ExternalPlugin.write({
	content: "external plugin worked\n",
}).rendered_config == "external plugin worked\n"
