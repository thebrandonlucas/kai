# Tools from pinned downloads, needing no Nix or Guix. FetchLocked names a
# file, or an archive and the program inside it, per system, with mirrors for
# the same bytes; `kai update` records each file's SHA-256 and size in the
# lock, and `kai update jq` measures jq's again. Expect names programs the
# machine must have, all checked before anything runs. Kai prefers Nix where
# it fits; these tools only direct can serve, so `kai run version` and the
# workflow of tasks `kai workflow check` need no provider at all.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

jq = "https://github.com/jqlang/jq/releases/download/jq-1.7.1"

actionlint = "https://github.com/rhysd/actionlint/releases/download/v1.7.12"

archive = |system, arch| {
	system,
	url: "${actionlint}/actionlint_1.7.12_linux_${arch}.tar.gz",
	mirrors: [],
	program: Archive("actionlint"),
}

kaifile = Std.kaifile([
	Name("direct"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	FetchLocked(
		"jq",
		[
			{
				system: "x86_64-linux",
				url: "${jq}/jq-linux-amd64",
				mirrors: [],
				program: File,
			},
			{
				system: "aarch64-linux",
				url: "${jq}/jq-linux-arm64",
				mirrors: [],
				program: File,
			},
		],
	),
	FetchLocked(
		"actionlint",
		[archive("x86_64-linux", "amd64"), archive("aarch64-linux", "arm64")],
	),
	Environment(
		"tools",
		[Tools(["jq#jq", "actionlint#actionlint"]), Expect(["sh"])],
	),
	Shell("default", [Use("tools")]),
	Task("version", [Use("tools"), Run(["jq", "--version"])]),
	Task("lint", [Use("tools"), Run(["actionlint", "--version"])]),
	Workflow("check", [RunTask("version", []), RunTask("lint", [])]),
])
