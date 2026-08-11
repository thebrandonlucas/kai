# A simple demo plugin. Its `config.kai` looks like:
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
import parser.Config
import kai.Plugin as PluginApi

CustomPlugin := [].{
	plugin : PluginApi.RegistryDefinition
	plugin = {
		definition,
		select_config: CustomPlugin.select_config,
	}

	local : PluginApi.Backend
	local = PluginApi.Backend.{
		determinate_system: PluginApi.DeterminateSystem.{
			default_package_source: "local",
			driver: NoDriver,
			kind: Custom,
		},
		fallback: NoFallback,
		name: "local",
		required_packages: [],
	}

	custom_body : Body.Shape
	custom_body = Body.object([
		Body.required(
			"message",
			String,
		),
	])

	custom_write : PluginApi.Command
	custom_write = PluginApi.Command.{
		argument_policy: NoArguments,
		body: custom_body,
		default_backend: local.name,
		name: "custom-write",
		config_block: RequiredConfigBlock("custom"),
	}

	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [
			WriteConfigUtf8({
				output: "message",
				path: "custom-plugin-output.txt",
			}),
		],
		backend: local.name,
		command: custom_write.name,
		renderer: CustomPlugin.render,
	}

	definition : PluginApi.Definition
	definition = PluginApi.Definition.{
		backends: [local],
		commands: [custom_write],
		implementations: [implementation],
		name: "custom",
	}

	render : PluginApi.Renderer
	render = |context|
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
						PluginApi.RenderResult.{
							outputs: [{ name: "message", text: message }],
							requested_packages: [],
						},
					)
				}
			}

	select_config : PluginApi.ConfigSelector
	select_config = |config_text, command, _, _, _| {
		block_name = match command.config_block {
			OptionalConfigBlock(name) => name
			RequiredConfigBlock(name) => name
		}
		blocks = Config.scan(config_text) ? |diagnostic| {
			location: At(CustomPlugin.source_location(diagnostic.location)),
			message: "invalid custom configuration",
		}
		selection = Config.select_exact(blocks, [block_name]) ? |selection_error| {
			location = match selection_error {
				DuplicateHeader({ first: _, header: _, second }) => At(CustomPlugin.source_location(second))
			}
			{ location, message: "duplicate custom configuration" }
		}
		match selection {
			Missing => Ok(Missing)
			Selected(block) => Ok(
				Selected({
					body: block.body,
					location: CustomPlugin.source_location(block.location),
				}),
			)
		}
	}

	source_location : Config.Location -> PluginApi.SourceLocation
	source_location = |location| {
		byte_offset: location.byte_offset,
		column: location.column,
		line: location.line,
	}
}
