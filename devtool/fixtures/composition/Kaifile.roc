# Test fixture (see devtool/fixtures/README.md), not an example.
# Imported pure functions compose ordinary settings for std and the guix
# plugin.
app [kaifile] {
	guix: "../../../plugins/guix/main.roc",
	pf: platform "../../../platform/main.roc",
	std: "../../../plugins/std/main.roc",
}

import ProjectTasks
import pf.Kaifile
import std.Config
import std.Std
import guix.Guix

project : List(Config.Setting)
project =
	[
		Name("composed"),
		Systems(["x86_64-linux", "aarch64-linux"]),
		Environment("base", [Tools(["git"])]),
		# Guix shells have no sh unless a tool provides it; Nix shells always do.
		Environment("dev", [Extend("base"), Tools(["bash", "coreutils", "git"])]),
		Shell("default", [Use("dev")]),
	].concat(ProjectTasks.settings("dev"))

kaifile = Kaifile.new([Std.plugin(project), Guix.plugin(project, [])])
