import kai.Body
import kai.Plugin as PluginApi

CustomPlugin := [].{
	plugin : PluginApi.Plugin
	# FIX: is module the "legacy" thing now according to the plans and we're 
	# just keeping it around for 
	plugin = PluginApi.Plugin.Module({
		definition,
		plan: CustomPlugin.plan,
	})

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
	custom_body = Body.object([Body.required("message", String)])

	custom_write : PluginApi.Command
	custom_write = PluginApi.Command.{
		argument_policy: NoArguments,
		body: custom_body,
		default_backend: local.name,
		name: "custom-write",
		source: RequiredSource("custom"),
	}

	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [WriteConfigUtf8({ output: "message", path: "custom-plugin-output.txt" })],
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
		match context.source {
			NoSource => Err({ byte_offset: None, message: "custom configuration is required" })
			SelectedSource({ body: _, location: _ }) =>
				match Body.get_string(context.config, "message") {
					Err(_) => Err({ byte_offset: None, message: "validated custom configuration is missing 'message'" })
					Ok(message) => Ok(
						PluginApi.RenderResult.{
							outputs: [{ name: "message", text: message }],
							requested_packages: [],
						},
					)
				}
			}

	plan : Str, List(Str), PluginApi.HostOs, PluginApi.HostArch -> Try(PluginApi.Plan, PluginApi.Error)
	plan = |source, args, _os, _arch|
		match args {
			["custom-write"] => {
				message = CustomPlugin.parse_message(source.split_on("\n"))?
				Ok(
					PluginApi.Plan.{
						actions: [WriteUtf8({ content: message, path: "custom-plugin-output.txt" })],
					},
				)
			}
			_ => Err(UnknownCommand)
		}

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
