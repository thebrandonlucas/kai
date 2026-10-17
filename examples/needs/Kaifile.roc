# A build can read other builds' artifacts: loud Needs moo, so kai builds moo
# first and loud reads it from $KAI_ARTIFACTS. `kai build loud`.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("needs"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay", "coreutils"])]),
	Build(
		"moo",
		[Use("cow"), Run(["sh", "-c", "cowsay moo > moo.txt"]), Output("moo.txt")],
	),
	Build(
		"loud",
		[
			Use("cow"),
			Needs(["moo"]),
			Run(["sh", "-c", "tr a-z A-Z < \"$KAI_ARTIFACTS/moo\" > loud.txt"]),
			Output("loud.txt"),
		],
	),
])
