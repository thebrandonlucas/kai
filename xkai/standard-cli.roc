# TODO: comment
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/${
		""
	}F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
	kai: "./package.roc",
	parser: "./parser/main.roc",
	std: "../plugins/std/main.roc",
}

import Executor
import kai.Plugin
import parser.Fields
import std.StdPlugin

registry = [StdPlugin.plugin]

main! = |args| Executor.run!(args, registry)
