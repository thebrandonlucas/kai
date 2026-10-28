# `Revision` gives a build the project's `git describe` and last commit date,
# which its sandbox cannot read from `.git`: `kai build version` keeps a
# version line stamped with them. Outside git both are empty.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("revision"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("base", [Tools(["coreutils"])]),
	Build(
		"version",
		[
			Use("base"),
			Revision,
			Run([
				"sh",
				"-c",
				"echo \"0.1.0 ($KAI_REVISION $KAI_COMMIT_DATE)\" > version",
			]),
			Output("version"),
			Files([]),
		],
	),
])
