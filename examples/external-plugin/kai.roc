app [config] {
	kai: platform "../../platform/main.roc",
	external: "./main.roc",
}

import external.ExternalPlugin

config = [ExternalPlugin.write({ content: "external plugin worked\n" })]
