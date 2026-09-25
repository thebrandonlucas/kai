# Test pure import recognition and effectful Kaifile composition.
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	parser: "./parser/main.roc",
	util: "../tests/util/main.roc",
}

import KaifileImports
import util.ImportCheck

expected =
	\\environment dev {
	\\  packages: ["cowsay", "fortune"]
	\\}
	\\
	\\shell {
	\\  environment: dev
	\\}

main! = |_| {
	actual = KaifileImports.load!("examples/imports/Kaifile")?
	if ImportCheck.expansion(actual.trim(), expected) {
		Ok({})
	} else {
		Err(UnexpectedExpansion({ actual, expected }))
	}
}

# An import line yields its relative import path.
expect {
	ImportCheck.line(
		"import \"parts/environment.kai\"",
		ImportPath("parts/environment.kai"),
	)
}
