app [config] {
	kai: platform "../../platform/main.roc",
	guix: "./main.roc",
}

import guix.GuixShellPlugin as P

config = [
	P.shell({
		pkgs: ["hello"],
	}),
]
