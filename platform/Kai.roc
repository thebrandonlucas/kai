import kai.Plugin as PluginApi

# Stable configuration shared by every plugin.
Kai := [].{
	ModuleConfig : {
		implementation : PluginApi.Implementation,
		rendered_config : Str,
	}

	render : List(ModuleConfig), List(Str) -> Try(Str, [MissingCommand, UnknownCommand(Str)])
	render = |modules, args| {
		command_args = args.drop_first(1)
		match command_args {
			[] => Err(MissingCommand)
			[command_name, ..] => {
				module_config = Kai.find_module(modules, command_name)?
				Ok(Json.to_str(PluginApi.lower(module_config.implementation, module_config.rendered_config)))
			}
		}
	}

	find_module : List(ModuleConfig), Str -> Try(ModuleConfig, [UnknownCommand(Str)])
	find_module = |modules, command_name|
		match modules {
			[] => Err(UnknownCommand(command_name))
			[first, .. as rest] =>
				if first.implementation.command.name == command_name {
					Ok(first)
				} else {
					Kai.find_module(rest, command_name)
				}
			}
}
