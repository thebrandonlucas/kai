app [config, module_changes] {
	kai: platform "../../platform/main.roc",
}

import kai.Kai

config = {
	name: "cowsay shell",
	shell: {
		pkgs: ["cowsay"],
	},
}

module_changes : List(Kai.CommandChange)
module_changes = []
