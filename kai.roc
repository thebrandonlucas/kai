app [config] {
	kai: platform "./platform/main.roc",
	std: "./plugins/main.roc",
}

import std.StdPlugin as P

config = [
	P.shell({
		pkgs: [
			# TODO:
			# A major goal is to "self-host" kai.
			#
			# i.e. when possible we will use kai for all the deps
			# required for kai.
			# Unfortunately we are blocked on true parity with
			# this project's flake.nix because we can't use
			# overlays yet (needed for roc nightly compiler)
			#
			# When we can we'll be able to self-host kai completely!
			"roc",
			"shfmt",
			"zig_0_16",
			"diffutils",
			"shfmt",
		],
	}),
]
