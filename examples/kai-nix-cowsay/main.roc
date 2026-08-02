app [config] {
	kai: platform "../../platform/main.roc",
	std: "../../plugins/main.roc",
}

import std.StdPlugin as Std

config = [
	Std.shell({
		pkgs: ["cowsay"],
	}),
]
