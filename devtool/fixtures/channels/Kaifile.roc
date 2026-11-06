# Test fixture (see devtool/fixtures/README.md), not an example.
# A Guix channel source beside generic tools, with the guix plugin beside
# std: the channels shell needs Guix, while generic tools use whichever
# backend is installed. On Guix, every command runs at the channel commit
# Kai's lock pins. The quote build reads a locked path: source.
#
# Its tools are `hello`, not cowsay like the examples: CI runs this fixture on
# real Guix with Nix absent, where Guix ships ready-made `hello` binaries,
# while cowsay would also download Perl and slow the long Guix CI job. The
# guix example uses cowsay because only Nix runs it in CI.
app [kaifile] {
	guix: "../../../plugins/guix/main.roc",
	pf: platform "../../../platform/main.roc",
	std: "../../../plugins/std/main.roc",
}

import pf.Kaifile
import std.Config
import std.Std
import guix.Guix

project : List(Config.Setting)
project = [
	Name("channels"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Packages("channels", From(GuixPackages("guix"))),
	Environment("dev", [Tools(["hello"])]),
	Environment("channels", [Tools(["channels#hello"])]),
	Shell("default", [Use("dev")]),
	Shell("channels", [Use("channels")]),
	Task("greet", [Use("dev"), Run(["hello", "--greeting"])]),
	Build(
		"greeting",
		[
			Use("dev"),
			Run(["sh", "-c", "hello > greeting.txt"]),
			Output("greeting.txt"),
		],
	),
	Source("words", "path:./words"),
	Build(
		"quote",
		[
			Use("dev"),
			Inputs(["words"]),
			Run([
				"sh",
				"-c",
				"hello --greeting \"$(cat \"$KAI_INPUTS/words/greeting.txt\")\" "
					.concat("> quote.txt"),
			]),
			Output("quote.txt"),
		],
	),
	Workflow("ci", [RunTask("greet", ["from ci"]), BuildArtifact("greeting")]),
]

kaifile = Kaifile.new([Std.plugin(project), Guix.plugin(project, [])])
