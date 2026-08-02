# Stable configuration shared by every plugin.
Kai := [].{
	ModuleConfig : {
		backend : Str,
		command : Str,
		source : Str,
	}

	render : List(ModuleConfig) -> Try(Str, [NoModulesConfigured])
	render = |modules|
		match modules {
			[] => Err(NoModulesConfigured)
			[first, ..] => Ok(first.source)
		}
}
