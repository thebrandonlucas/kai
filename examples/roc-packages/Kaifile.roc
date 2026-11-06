# Roc package bundles placed in Roc's package cache before a shell or task
# starts, so a Roc program importing them resolves them without downloading.
# `kai update` pins each bundle's SHA-256 in the lock. The direct backend
# serves `scripts`, which has no package-source tools, downloading the bundle
# into kai's store; Nix serves `nix`, fetching it as a fixed-output file. A
# real project lists every bundle its programs import, dependencies of
# dependencies too: `roc deps <file>` prints them.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

http = "https://github.com/roc-lang/http/releases/download/1.0.0"

hash = "6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS"

cache = "\${XDG_CACHE_HOME:-$HOME/.cache}/roc/packages"

placed = ["sh", "-c", "test -f \"${cache}/${hash}/main.roc\" && echo placed"]

kaifile = Std.kaifile([
	Name("roc-packages"),
	Environment(
		"scripts",
		[RocPackages(["${http}/${hash}.tar.zst"]), Expect(["sh"])],
	),
	Environment("nix", [Extend("scripts"), Tools(["hello"])]),
	Task("placed", [Use("scripts"), Run(placed)]),
	Task("placed-on-nix", [Use("nix"), Run(placed)]),
])
