app [config] {
	kai: platform "../../platform/main.roc",
}

import kai.Kai

config : Kai.Config
config = {
	shell: {
		pkgs: ["cowsay"],
	},
}
