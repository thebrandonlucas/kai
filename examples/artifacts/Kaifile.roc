# Two sandboxed artifacts: a library built from a fresh snapshot of the
# project, and an app that reads the locked assets source and the library.
app [config] { pf: platform "../../kaifile/platform/main.roc" }

config = [
	Name("artifacts"),
	Systems(["x86_64-linux"]),
	Environment("dev", [Tools(["python3"])]),
	Source("assets", "path:./assets"),
	Build(
		"library",
		[
			Use("dev"),
			Run(["python3", "scripts/build_library.py"]),
			Output("dist/library.txt"),
		],
	),
	Build(
		"app",
		[
			Use("dev"),
			Inputs(["assets"]),
			Needs(["library"]),
			Run(["python3", "scripts/build_app.py"]),
			Output("dist/app.txt"),
		],
	),
]
