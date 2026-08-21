import kai.Plugin

Guix := [].{
	backend : Plugin.Backend
	backend = Plugin.Backend.{
		determinate_system: Plugin.DeterminateSystem.{
			default_package_source: "guix",
			driver: Program("guix"),
			kind: Guix,
		},
		fallback: NoFallback,
		name: "guix",
		required_packages: [],
	}

	supported_targets : List(Plugin.BackendTarget)
	supported_targets = [
		{ arch: X64, os: LINUX, value: "x86_64-linux" },
		{ arch: AARCH64, os: LINUX, value: "aarch64-linux" },
	]

	package_rules : List(Plugin.StringListRule)
	package_rules = [
		NonemptyStringList("shell requires at least one package specification"),
		AllStrings(NonemptyText("shell package specifications must not be empty")),
		AllStrings(DisallowedPrefix({ message: "shell package specifications must not begin with '-'", prefix: "-" })),
	]
}
