# A simple demo plugin. It's `config.kai` looks like:
#
# ```Kaifile
#   custom {
#      message: "..."
#   }
# ```
import kai.Body
import kai.Plugin as PluginApi

CustomPlugin := [].{
	plugin : PluginApi.Plugin
	# FIX: is module the "legacy" thing now according to the plans and we're 
	# just keeping it around for backward compat while we build the new Registry
	# system?
	plugin = PluginApi.Plugin.Module({
		definition,
		plan: CustomPlugin.plan,
	})

	local : PluginApi.Backend
	local = PluginApi.Backend.{
		determinate_system: PluginApi.DeterminateSystem.{
			# FIX: assuming "local" is what we're calling our 
			# determinate package manager nix or guix equivalent
			default_package_source: "local",
			# FIX: assuming Driver means "which program drives this?"
			# is this supposed to be the actual "nix" cli tool (if the system were nix?)
			driver: NoDriver,
			kind: Custom,
		},
		# FIX: fallback describes what behavior to do if 
		fallback: NoFallback,
		name: "local",
		required_packages: [],
	}

	# FIX body describes the "body of the config within the curly block"
	# but what does Shape mean?
	# I supposed Body.object is just a typed array of requirements and definitions
	# for anything in the body of the config 
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
		# FIX what is RequiredSource
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

	# FIX this fn seems to be typed improperly? it takes in a value
	# and returns a value but that's not represented in the type def?
	# do all plugin's need a renderer?
	render : PluginApi.Renderer
	render = |context|
		match context.config_block {
			NoConfigBlock => Err({ byte_offset: None, message: "custom configuration is required" })
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

	# FIX do all plugins need a plan?
	plan :
		Str,
		List(Str),
		PluginApi.HostOs,
		PluginApi.HostArch ->
			Try(
				PluginApi.Plan,
				PluginApi.Error,
			)
	plan = |config_text, args, _os, _arch|
		match args {
			["custom-write"] => {
				message = CustomPlugin.parse_message(config_text.split_on("\n"))?
				Ok(
					PluginApi.Plan.{
						actions: [WriteUtf8({ content: message, path: "custom-plugin-output.txt" })],
					},
				)
			}
			_ => Err(UnknownCommand)
		}

	# Parses the message part of the body in the custom plugin
	parse_message : List(Str) -> Try(Str, [InvalidConfig])
	parse_message = |lines|
		match lines {
			[] => Err(InvalidConfig)
			[first, .. as rest] => {
				line = first.trim()
				if line.starts_with("message:") {
					decoded : Try(Str, Json.ParseErr)
					decoded = Json.parse(line.drop_prefix("message:").trim())
					match decoded {
						Ok(message) => Ok(message)
						Err(_) => Err(InvalidConfig)
					}
				} else {
					CustomPlugin.parse_message(rest)
				}
			}
		}
}

# parse_message extracts message field from config.kai string
#
# Input:
# custom {
#   message: "custom plugin worked"
# }
# Expected output: "custom plugin worked"
expect CustomPlugin.parse_message([
	"custom {",
	"message: \"custom plugin worked\"",
	"}",
]) == Ok("custom plugin worked")
