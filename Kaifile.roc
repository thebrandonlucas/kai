# Kai's own development environment. Until it names released bundles, it
# loads this checkout's platform, whose hosts `zig build` builds first.
app [kaifile] {
	pf: platform "platform/main.roc",
	std: "plugins/std/main.roc",
}

import std.FlakeRef
import std.Std
import std.Tool

import ".roc-overlay" as roc_overlay : Str
import ".roc-version" as roc_version : Str

# The Roc compiler .roc-version pins, from the roc-overlay .roc-overlay pins,
# as kai itself gets it.
overlay =
	FlakeRef.from_quote(roc_overlay.trim()).map_ok(|ref| [Overlay("roc", ref)])
		?? []

roc = Tool.from_quote("rocpkgs.${roc_version.trim()}").map_ok(|t| [t]) ?? []

kaifile = Std.kaifile(
	[Name("kai")].concat(overlay).concat([
		Environment(
			"dev",
			[
				Overlays(["roc"]),
				Tools(
					roc.concat([
						"zig_0_16",
						"actionlint",
						"coreutils",
						"file",
						"git",
						"gnutar",
						"gzip",
						"jujutsu",
						"llvmPackages.bintools",
						"nixfmt",
						"sops",
					]),
				),
			],
		),
		Shell("default", [Use("dev")]),
	]),
)
