app [config] {
	kai: platform "../../platform/config.roc",
}

import kai.Kai

config : Kai.Config
config = {
	name: "cowsay shell",
	shell: {
		pkgs: ["cowsay"],
	},
}
