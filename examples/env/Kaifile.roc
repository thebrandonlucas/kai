# `Env` sets environment variables. Variables set on a kai `Environment`
# reach every shell, task and build that uses it, and a task's or build's
# own `Env` overrides them. `kai run moo` has the cow say "Moo", from the
# cow `Environment`; `kai run shout` has it say "MOO!", from the task.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

say = Run(["sh", "-c", "cowsay \"$GREETING\""])

kaifile = Std.kaifile([
	Name("env"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay"]), Env([("GREETING", "Moo")])]),
	Shell("default", [Use("cow")]),
	Task("moo", [Use("cow"), say]),
	Task("shout", [Use("cow"), Env([("GREETING", "MOO!")]), say]),
	# `kai build greeting` keeps the build's own GREETING in a file.
	Build(
		"greeting",
		[
			Use("cow"),
			Env([("GREETING", "Built moo")]),
			Run(["sh", "-c", "cowsay \"$GREETING\" > greeting"]),
			Output("greeting"),
			Files([]),
		],
	),
])
