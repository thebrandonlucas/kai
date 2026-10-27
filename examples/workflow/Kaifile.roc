# Workflows run tasks, builds and other workflows in order and stop at the
# first failure, unless the step may fail: `kai workflow encore` runs the
# whole cowvolution, lets the grumpy cow fail, then moos again.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("workflow"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay"])]),
	Task("normalcow", [Use("cow"), Run(["cowsay", "moo"])]),
	Task(
		"antiquitycow",
		[Use("cow"), Run(["cowsay", "Non nobis solum nati sumus."])],
	),
	Task(
		"victoriancow",
		[Use("cow"), Run(["cowsay", "doth mother know you weareth her drapes?"])],
	),
	Task("grumpycow", [Use("cow"), Run(["sh", "-c", "cowsay grumble; exit 1"])]),
	Build(
		"moderncow",
		[
			Use("cow"),
			Run([
				"sh",
				"-c",
				"printf '#!%s\\nexec %s \"\${*:-like, whateverrrr}\"\\n' "
					.concat("\"$(command -v sh)\" \"$(command -v cowsay)\" > moderncow ")
					.concat("&& chmod +x moderncow"),
			]),
			Output("moderncow"),
		],
	),
	Workflow(
		"cowvolution",
		[
			RunTask("normalcow", []),
			RunTask("antiquitycow", []),
			RunTask("victoriancow", []),
			BuildArtifact("moderncow"),
		],
	),
	Workflow(
		"encore",
		[
			RunWorkflow("cowvolution"),
			MayFail(RunTask("grumpycow", [])),
			RunTask("normalcow", ["again"]),
		],
	),
])
