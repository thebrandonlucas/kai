# Pinned downloads from std's Downloads helpers, for each declared system: a
# Roc nightly's compiler, by its tag, and a program released as one file per
# system, named in its URL. `kai update` pins each file in the lock, as it
# would FetchLocked entries written out, and `kai run version` runs both on
# the direct backend. `kai spec` shows the URLs and program paths they give.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Downloads
import std.Std

systems = ["x86_64-linux", "aarch64-darwin"]

nightly = "nightly-2026-10-21-5349569"

tools = "https://github.com/lukewilliamboswell/roc-automation/releases/download"

kaifile = Std.kaifile([
	Name("downloads"),
	Systems(systems),
	FetchLocked("roc", Downloads.roc_nightly(nightly, systems)),
	FetchLocked(
		"release-package",
		Downloads.file("${tools}/tools-0.10.0/release-package-{system}", systems),
	),
	Environment(
		"tools",
		[Tools(["roc#roc", "release-package#release-package"]), Expect(["sh"])],
	),
	Task(
		"version",
		[
			Use("tools"),
			Run(["sh", "-c", "roc version && command -v release-package"]),
		],
	),
])
