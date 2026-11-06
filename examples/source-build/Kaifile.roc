# Builds can read locked sources: `kai update` locks the original cowsay
# 3.04 release to its commit, and `kai build moofasa` draws its moofasa cow from
# that source, read through $KAI_INPUTS. Only builds that list a source in
# Inputs can read it, and a source may not contain symlinks.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("source-build"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Source(
		"cows",
		"github:tnalpgge/rank-amateur-cowsay/cowsay-3.04",
	),
	Environment("cow", [Tools(["cowsay"])]),
	Build(
		"moofasa",
		[
			Use("cow"),
			Inputs(["cows"]),
			Run([
				"sh",
				"-c",
				"cowsay -f \"$KAI_INPUTS/cows/cows/moofasa.cow\" moo "
					.concat("> moofasa.txt"),
			]),
			Output("moofasa.txt"),
		],
	),
	# Every build gets $KAI_TOOLS, a link to each tool of its environment, and
	# $KAI_INPUTS/.kai-inputs.json, a record of its inputs, to say what made
	# it: `kai build evidence` keeps the record and each tool's store name,
	# such as cowsay-3.8.4, without the hash, which would keep the tool in
	# the artifact's closure.
	Build(
		"evidence",
		[
			Use("cow"),
			Inputs(["cows"]),
			Run(["sh", "-c", evidence]),
			Output("evidence"),
		],
	),
])

evidence =
	\\mkdir evidence
	\\cp "$KAI_INPUTS/.kai-inputs.json" evidence/inputs.json
	\\for tool in "$KAI_TOOLS"/*; do
	\\  echo "$(basename "$tool") $(readlink "$tool" | cut -d- -f2-)"
	\\done > evidence/tools.txt
