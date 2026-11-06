# Tools from pinned downloads, needing no Nix or Guix. FetchLocked names a
# file, or an archive (a tarball or a zip) and the program inside it, per
# system, with mirrors for the same bytes; `kai update` records each file's
# SHA-256 and size in the lock, on every declared system, Intel macOS
# included though neither Nix nor Guix serves it, and `kai update jq`
# measures jq's again. Expect names programs the machine must have, all
# checked before anything runs. Kai prefers Nix where it fits; these tools
# only direct can serve, so `kai run version` and the workflow of tasks `kai
# workflow check` need no provider at all. `kai lock` prints the pins as JSON.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

jq = "https://github.com/jqlang/jq/releases/download/jq-1.7.1"

actionlint = "https://github.com/rhysd/actionlint/releases/download/v1.7.12"

ninja = "https://github.com/ninja-build/ninja/releases/download/v1.12.1"

file = |system, name|
	{ system, url: "${jq}/${name}", mirrors: [], program: File }

archive = |system, os_arch| {
	system,
	url: "${actionlint}/actionlint_1.7.12_${os_arch}.tar.gz",
	mirrors: [],
	program: Archive("actionlint"),
}

zip = |system, name| {
	system,
	url: "${ninja}/${name}.zip",
	mirrors: [],
	program: Archive("ninja"),
}

kaifile = Std.kaifile([
	Name("direct"),
	Systems(["x86_64-linux", "aarch64-linux", "x86_64-darwin"]),
	FetchLocked(
		"jq",
		[
			file("x86_64-linux", "jq-linux-amd64"),
			file("aarch64-linux", "jq-linux-arm64"),
			file("x86_64-darwin", "jq-macos-amd64"),
		],
	),
	FetchLocked(
		"actionlint",
		[
			archive("x86_64-linux", "linux_amd64"),
			archive("aarch64-linux", "linux_arm64"),
			archive("x86_64-darwin", "darwin_amd64"),
		],
	),
	FetchLocked(
		"ninja",
		[
			zip("x86_64-linux", "ninja-linux"),
			zip("aarch64-linux", "ninja-linux-aarch64"),
			zip("x86_64-darwin", "ninja-mac"),
		],
	),
	Environment(
		"tools",
		[
			Tools(["jq#jq", "actionlint#actionlint", "ninja#ninja"]),
			Expect(["sh"]),
		],
	),
	Shell("default", [Use("tools")]),
	Task("version", [Use("tools"), Run(["jq", "--version"])]),
	Task("lint", [Use("tools"), Run(["actionlint", "--version"])]),
	Task("ninja", [Use("tools"), Run(["ninja", "--version"])]),
	Workflow(
		"check",
		[RunTask("version", []), RunTask("lint", []), RunTask("ninja", [])],
	),
])
