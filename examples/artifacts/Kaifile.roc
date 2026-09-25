# Two sandboxed artifacts: a library built from a fresh snapshot of the
# project, and an app that reads the locked assets source and the library.
# The ci workflow checks the working tree, then builds the app.
app [config] { pf: platform "../../kaifile/platform/main.roc" }

config = [
	Name("artifacts"),
	Systems(["x86_64-linux"]),
	Environment("dev", [Tools(["coreutils"])]),
	# An ordinary unsandboxed task checks working-tree source, not an artifact.
	Task(
		"check",
		[
			Use("dev"),
			Run([
				"sh",
				"-c",
				\\[ -s src/message.txt ] && [ -z "$(tail -c 1 src/message.txt)" ] ||
				\\{ echo 'src/message.txt must end with a newline' >&2; exit 1; }
				\\echo source checked
				,
			]),
		],
	),
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
	Workflow("ci", [RunTask("check", []), BuildArtifact("app")]),
]
