# Imported pure functions compose ordinary settings, without a plugin registry.
app [config] { pf: platform "../../kaifile/platform/main.roc" }

import ProjectTasks

config = [
	Name("composed"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("base", [Tools(["git"])]),
	Environment("dev", [Extend("base"), Tools(["coreutils", "git"])]),
	Shell("default", [Use("dev")]),
].concat(ProjectTasks.settings("dev"))
