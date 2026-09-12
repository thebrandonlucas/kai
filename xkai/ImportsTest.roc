# Test pure import recognition and effectful Kaifile composition.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
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

expect {
	ImportCheck.line(
		"import \"parts/environment.kai\"",
		ImportPath("parts/environment.kai"),
	)
}
