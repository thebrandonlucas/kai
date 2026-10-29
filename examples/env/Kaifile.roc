# `Env` sets environment variables. Variables set on a kai `Environment`
# reach every shell, task and build that uses it, and a task's or build's
# own `Env` overrides them. `kai run moo` has the cow say "Moo", from the
# cow `Environment`; `kai run shout` has it say "MOO!", from the task.
# `Pure` starts a shell or task from a clean environment, but for HOME, USER
# and TERM, so `kai run calm` sees only what its environments declare.
# `PackageEnv` sets variables to paths in packages, such as a library path:
# `kai run libraries` checks them.
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
	Environment("calm", [Extend("cow"), Pure]),
	Task("calm", [Use("calm"), say]),
	Environment(
		"libraries",
		[
			Extend("cow"),
			PackageEnv([
				("LD_LIBRARY_PATH", LibraryPath(["zlib"])),
				("COW_BIN", BinPath(["cowsay"])),
				("COWSAY", PackagePath("cowsay")),
			]),
		],
	),
	Task(
		"libraries",
		[
			Use("libraries"),
			Run([
				"sh",
				"-c",
				"test -e \"$LD_LIBRARY_PATH/libz.so\" && "
					.concat("test \"$COW_BIN\" = \"$COWSAY/bin\""),
			]),
		],
	),
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
