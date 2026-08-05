app [config] {
	kai: platform "../../platform/main.roc",
	external: "./main.roc",
}

import external.ExternalPlugin as P

config = [
	P.write({
		content: "external plugin worked\n",
	}),
]
