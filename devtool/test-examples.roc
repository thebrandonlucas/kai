app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "../xkai-bin/package.roc",
	parser: "../xkai-bin/parser/main.roc",
	std: "../plugins/std/main.roc",
}

import pf.OsStr

import Examples

main! : List(OsStr) => Try({}, _)
main! = |args|
	match args.drop_first(1).map(OsStr.display) {
		[directory] => Examples.run!(directory)
		_ => Err(InvalidArguments("Usage: kai-test-examples DIRECTORY"))
	}
