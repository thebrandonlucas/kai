# One environment with a tool from a package source, a pinned download and a
# program the machine must have. On Nix, `kai run greet` checks that sh is
# on PATH, makes jq ready from kai's store, and runs with jq first on PATH,
# beside hello from nixpkgs. The direct backend refuses this environment,
# naming hello, as only Nix has package sources; `kai update` pins both.
# `kai workflow both` runs greet on Nix and a task whose environment is only
# downloads on direct, each step on the backend that serves it.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

jq = "https://github.com/jqlang/jq/releases/download/jq-1.7.1"

kaifile = Std.kaifile([
	Name("mixed"),
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
	Environment("tools", [Tools(["hello", "jq#jq"]), Expect(["sh"])]),
	Task("greet", [Use("tools"), Run(["sh", "-c", "hello && jq --version"])]),
	# Only downloads: the direct backend serves it, and Nix leaves it to direct.
	Environment("downloads", [Tools(["jq#jq"])]),
	Task("version", [Use("downloads"), Run(["jq", "--version"])]),
	# Each step on the backend that serves it, as `kai run` would choose:
	# greet on Nix, then version on direct.
	Workflow("both", [RunTask("greet", []), RunTask("version", [])]),
])
