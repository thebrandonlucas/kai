# Imported pure functions compose ordinary settings for std.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import ProjectTasks
import std.Std

kaifile = Std.kaifile(
	[
		Name("composed"),
		Systems(["x86_64-linux", "aarch64-linux"]),
		Environment("base", [Tools(["git"])]),
		Environment("dev", [Extend("base"), Tools(["coreutils", "git"])]),
		Shell("default", [Use("dev")]),
	].concat(ProjectTasks.settings("dev")),
)
