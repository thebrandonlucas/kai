# A Fetch pins a file by its published sha256, one for each system, with no
# lock entry: here jq's release binary. `kai run version` runs it as the tool
# jq#jq, and `kai build checksum` reads it at $KAI_INPUTS/jq in the sandbox.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

release = "https://github.com/jqlang/jq/releases/download/jq-1.7.1"

kaifile = Std.kaifile([
	Name("fetch"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Fetch(
		"jq",
		[
			{
				system: "x86_64-linux",
				url: "${release}/jq-linux-amd64",
				sha256: "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5",
			},
			{
				system: "aarch64-linux",
				url: "${release}/jq-linux-arm64",
				sha256: "4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5",
			},
		],
	),
	Environment("json", [Tools(["jq#jq"])]),
	Task("version", [Use("json"), Run(["jq", "--version"])]),
	Build(
		"checksum",
		[
			Use("json"),
			Inputs(["jq"]),
			Run(["sh", "-c", "sha256sum \"$KAI_INPUTS/jq\" > jq.sha256"]),
			Output("jq.sha256"),
		],
	),
])
