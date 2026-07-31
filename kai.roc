KaiProject := [].{
	config = {
		name: "Kai developer shell",
		shell: {
			pkgs: [
				# TODO: Unfortunately we are blocked on true parity with
				#       this project's flake.nix because we can't use
				#       overlays yet (needed for roc nightly compiler)
				#
				#       When we can we'll be able to self-host kai completely!
				"roc",
				"zig_0_16",
				"diffutils",
				"shfmt",
			],
		},
	}
}
