# A simple demo plugin. Its `Kaifile` looks like:
#
# ```Kaifile
#   custom {
#      message: "Hello from CustomPlugin!"
#   }
# ```
#
# Building with `xkai build` and then running with
# `./kai custom-write` should create a file called
# "custom-plugin-output.txt" with the message "Hello from CustomPlugin!"

import parser.Fields
import kai.Kaifile
import kai.Plugin

CustomPlugin := [].{
	plugin : Plugin.Definition
	plugin = Plugin.Definition.{
		backends,
		implementations,
		name,
		schema,
	}

	name = "custom"

	block : Plugin.KaifileBlock
	block = Kaifile.unnamed_block({
		header: "custom",
		fields: [Kaifile.required("message", String)],
	})

	command : Plugin.Command
	command = Plugin.command("custom-write", [])

	command_schema : Plugin.CommandSchema
	command_schema = Plugin.command_with_block({ command, block })

	schema : Plugin.Schema
	schema = { blocks: [block], commands: [command_schema] }

	backends : List(Plugin.Backend)
	backends = [
		Plugin.Backend.{
			determinate_system: Plugin.DeterminateSystem.{
				default_package_source: "local",
				driver: NoDriver,
				kind: Custom,
			},
			fallback: NoFallback,
			name: "local",
			required_packages: [],
		},
	]

	implementations : List(Plugin.Implementation)
	implementations = [
		Plugin.Implementation.{
			backend: "local",
			command: command.name,
			plan: |input|
				match Fields.get_string(input.command_fields, "message") {
					Err(_) => Err({
						byte_offset: None,
						message: "validated custom block is missing 'message'",
					})
					Ok(message) => Ok(
						Plugin.CommandPlan.{
							artifacts: [],
							prerequisite_commands: [],
							requested_packages: [],
							steps: [
								WriteFile({
									contents: message,
									path: "custom-plugin-output.txt",
								}),
							],
						},
					)
				},
			validator: NoValidation,
		},
	]
}
