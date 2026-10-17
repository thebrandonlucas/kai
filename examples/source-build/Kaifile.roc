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
])
