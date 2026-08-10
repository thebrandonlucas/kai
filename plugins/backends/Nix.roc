import kai.Plugin as PluginApi

Nix := [].{
	backend : PluginApi.Backend
	backend = PluginApi.Backend.{
		determinate_system: PluginApi.DeterminateSystem.{
			default_package_source: "nixpkgs",
			driver: Program("nix"),
			kind: Nix,
		},
		fallback: NoFallback,
		name: "nix",
		required_packages: [],
	}
}
