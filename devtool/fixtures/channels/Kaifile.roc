# Test fixture (see devtool/fixtures/README.md), not an example.
# A Guix channel source beside generic tools: the channels shell needs Guix,
# while generic tools use whichever backend is installed. On Guix, every
# command runs at the channel commit Kai's lock pins. The build takes no
# inputs, which Guix builds do not support yet.
#
# Its tools are `hello`, not cowsay like the examples: CI runs this fixture on
# real Guix with Nix absent, where Guix ships ready-made `hello` binaries,
# while cowsay would also download Perl and slow the long Guix CI job. The
# guix example uses cowsay because only Nix runs it in CI.
app [kaifile] {
	pf: platform "../../../platform/main.roc",
	std: "../../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
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
	Workflow("ci", [RunTask("greet", ["from ci"]), BuildArtifact("greeting")]),
])
