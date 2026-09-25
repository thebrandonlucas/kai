# Two sandboxed artifacts: a library built from a fresh snapshot of the
# project, and an app that reads the locked assets source and the library.
app [config] { pf: platform "../../kaifile/platform/main.roc" }

config = [
	Name("artifacts"),
	Systems(["x86_64-linux"]),
	Environment("dev", [Tools(["coreutils"])]),
	Source("assets", "path:./assets"),
	# Built from the current project snapshot, not from a locked Source.
	Build(
		"library",
		[
			Use("dev"),
			Run([
				"sh",
				"-c",
				"mkdir dist && tr a-z A-Z < src/message.txt > dist/library.txt",
			]),
			Output("dist/library.txt"),
		],
	),
	# Inputs and Needs are read-only store paths, apart from the writable
	# project copy the build runs in.
	Build(
		"app",
		[
			Use("dev"),
			Inputs(["assets"]),
			Needs(["library"]),
			Run([
				"sh",
				"-c",
				"mkdir dist && cat \"$KAI_INPUTS/assets/heading.txt\" "
					.concat("\"$KAI_ARTIFACTS/library\" > dist/app.txt"),
			]),
			Output("dist/app.txt"),
		],
	),
]
