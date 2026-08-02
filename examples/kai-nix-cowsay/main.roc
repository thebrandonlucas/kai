app [config] {
	kai: platform "../../platform/main.roc",
	std: "../../plugins/main.roc",
}

import std.StdConfig

config = [
	StdConfig.shell({ pkgs: ["cowsay"] }),
]
