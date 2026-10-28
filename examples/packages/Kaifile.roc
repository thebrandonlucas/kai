# Every tool comes from a named package source. Plain names like "fortune"
# come from "default", which is nixos-unstable unless you declare it yourself.
# Here "stable" is a second source pinned to the NixOS 25.05 release, and
# "stable#cowsay" takes cowsay from it. Both install `bin/cowsay`, so Alias
# puts unstable's on PATH as `cowsay-unstable`. Input pins any other flake in
# the lock.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("packages"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Packages("default", Auto),
	Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-25.05"))),
	Input("utils", "github:numtide/flake-utils"),
	Environment(
		"cow",
		[
			Tools(["stable#cowsay", "fortune"]),
			Alias("cowsay-unstable", "cowsay", "cowsay"),
		],
	),
	Shell("default", [Use("cow")]),
])
