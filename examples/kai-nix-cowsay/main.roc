app [config] {
	kai: platform "../../platform/main.roc",
}

import kai.Kai

config : Kai.Config
config = {
	name: "cowsay shell",
	shell: {
		pkgs: ["cowsay"],
	},
}
