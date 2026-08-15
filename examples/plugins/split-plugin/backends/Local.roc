import kai.Plugin as PluginApi

Local := [].{
	backend : PluginApi.Backend
	backend = PluginApi.Backend.{
		determinate_system: PluginApi.DeterminateSystem.{
			default_package_source: "local",
			driver: NoDriver,
			kind: Custom,
		},
		fallback: NoFallback,
		name: "local",
		required_packages: [],
	}
}
