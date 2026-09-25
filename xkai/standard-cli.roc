# TODO: comment
app [main!] {
	pf: platform "../.basic-cli/main.roc",
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
