app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "./package.roc",
	parser: "./parser/main.roc",
	std: "../plugins/std/main.roc",
}

import Executor
import kai.Plugin
import parser.Body
import std.StdPlugin

registry = [StdPlugin.plugin]

main! = |args| Executor.run!(args, registry)
