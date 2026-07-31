import kai.Kai

KaiProject := [].{
	project = {
		name: "Kai developer shell",
		shell: {
			pkgs: [
				# TODO: Unfortunately we are blocked on true parity with
				#       this project's flake.nix because we can't use
				#       overlays yet (needed for roc nightly compiler)
				#
				#       When we can we'll be able to self-host kai completely!
				"roc",
				"shfmt",
				"zig_0_16",
				"diffutils",
				"shfmt",
			],
		},
	}

	config : Kai.Config
	config = Kai.config(project)

}
