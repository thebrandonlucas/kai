import kai.Plugin as PluginApi

CustomPlugin := [].{
	plugin : PluginApi.Plugin
	plugin = PluginApi.Plugin.Module({ name: "custom", plan: CustomPlugin.plan })

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

expect CustomPlugin.parse_message(["custom {", "message: \"custom plugin worked\"", "}"]) == Ok("custom plugin worked")
