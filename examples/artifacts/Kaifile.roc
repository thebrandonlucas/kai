# Two sandboxed artifacts: a library built from a fresh snapshot of the
# project, and an app that reads the locked assets source and the library.
# The ci workflow checks the working tree, then builds the app.
app [config] { pf: platform "../../kaifile/platform/main.roc" }

config = [
	Name("artifacts"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("dev", [Tools(["python3"])]),
	Task("check", [Use("dev"), Run(["python3", "scripts/check.py"])]),
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
	Workflow("ci", [RunTask("check", []), BuildArtifact("app")]),
]
