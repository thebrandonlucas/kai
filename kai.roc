app [config] {
	kai: platform "./platform/config.roc",
}

import kai.Kai

config : Kai.Config
config = {
	name: "Kai developer shell",
	shell: {
		pkgs: ["roc"],
	},
}
