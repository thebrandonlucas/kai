import kai.Plugin as PluginApi

# Stable configuration shared by every plugin.
Kai := [].{
	ModuleConfig : {
		implementation : PluginApi.Implementation,
		rendered_config : Str,
	}

	render : List(ModuleConfig) -> Try(Str, [NoModulesConfigured])
	render = |modules|
		match modules {
			[] => Err(NoModulesConfigured)
			[first, ..] =>
				Ok(Json.to_str(PluginApi.lower(first.implementation, first.rendered_config)))
			}
}
