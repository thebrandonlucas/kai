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

import parser.Body
import kai.Plugin

CustomPlugin := [].{
	name = "custom"

	commands : List(Plugin.Command)
	commands = [
		Plugin.Command.{
			argument_policy: NoArguments,
			body: Body.object([
				Body.required(
					"message",
					String,
				),
			]),
			config: DirectConfig(QualifiedThenUnqualified),
			config_block: RequiredConfigBlock("custom"),
			name: "custom-write",
		},
	]

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
			actions: [
				WriteConfigUtf8({
					output: "message",
					path: "custom-plugin-output.txt",
				}),
			],
			backend: "local",
			command: "custom-write",
			renderer: |context|
				match context.config_block {
					NoConfigBlock => Err({
						byte_offset: None,
						message: "custom configuration is required",
					})
					SelectedConfigBlock({ body: _, location: _ }) =>
						match Body.get_string(context.config, "message") {
							Err(_) => Err({
								byte_offset: None,
								message: "validated custom configuration is missing 'message'",
							})
							Ok(message) => Ok(
								Plugin.RenderResult.{
									actions: [],
									outputs: [{ name: "message", text: message }],
									requests: [],
									requested_packages: [],
								},
							)
						}
					},
			validator: NoValidation,
		},
	]
}
