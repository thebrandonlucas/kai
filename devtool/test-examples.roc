# Test the examples in ../examples
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	kai: "../xkai/package.roc",
	parser: "../xkai/parser/main.roc",
	std: "../plugins/std/main.roc",
}

import pf.OsStr

import Examples

main! : List(OsStr) => Try({}, _)
main! = |args| {
	directories = args.map(OsStr.display)
	if directories.is_empty() {
		Err(
			InvalidArguments(
				"Usage: kai-test-examples DIRECTORY [DIRECTORY...]",
			),
		)
	} else {
		Examples.run!(directories)
	}
}
