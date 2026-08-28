# Test the examples in ../examples
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/${
		""
	}F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
	kai: "../xkai/package.roc",
	parser: "../xkai/parser/main.roc",
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
