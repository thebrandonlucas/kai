# Kai's own development environment. Until it names released bundles, it
# loads this checkout's platform, whose hosts `zig build` builds first.
app [kaifile] {
	pf: platform "platform/main.roc",
	std: "plugins/std/main.roc",
}

import std.FlakeRef
import std.InputName
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

# The Roc packages the platform imports (Weaver, which imports ansi and path),
# as flake.nix fetches them, each named by its hash as Roc caches it.
roc_packages = [
	(
		"lukewilliamboswell/weaver/releases/download/0.9.0",
		"7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77",
	),
	(
		"lukewilliamboswell/roc-ansi/releases/download/0.13.0",
		"JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL",
	),
	(
		"roc-lang/path/releases/download/4.0.0",
		"7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE",
	),
]

roc_inputs = List.keep_oks(roc_packages, |(_, name)| InputName.from_quote(name))

roc_sources = List.keep_oks(
	roc_packages,
	|(release, name)| {
		url = "tarball+https://github.com/${release}/${name}.tar.zst"
		Ok(Source(InputName.from_quote(name)?, FlakeRef.from_quote(url)?))
	},
)

# Seeds Roc's package cache with the Inputs, runs script to fill stage/ and
# add packages, and bundles stage/ as flake.nix's kaiPlatformFor and kaiStdFor
# do: bundle/ holds <hash>.tar.zst, and that unpacked as <hash>/.
bundle = |script|
	\\set -eu
	\\export XDG_CACHE_HOME="$HOME/.cache" ZIG_GLOBAL_CACHE_DIR="$HOME/zig"
	\\packages="$XDG_CACHE_HOME/roc/packages"
	\\mkdir -p "$packages" stage bundle
	\\cp -RL "$KAI_INPUTS"/. "$packages/"
	\\
		.concat(script)
		.concat(
			\\
			\\chmod -R u+w "$packages"
			\\cd stage
			\\files="$(find . -type f ! -path ./main.roc | LC_ALL=C sort)"
			\\roc bundle main.roc $files --output-dir ../bundle
			\\cd ../bundle
			\\name="$(basename *.tar.zst .tar.zst)"
			\\mkdir "$name"
			\\zstd -dc "$name.tar.zst" | tar -x -C "$name"
		)

platform_script =
	\\(cd platform && zig build --release)
	\\(cd platform/targets && sha256sum --quiet -c x64musl.sha256 arm64musl.sha256)
	\\mkdir stage/targets
	\\cp platform/*.roc stage/
	\\cp -R platform/targets/x64musl platform/targets/arm64musl stage/targets/

# std's own packages reach the platform's modules through api.roc; bundled,
# they depend on the platform itself, by the URL this release publishes it at.
std_script =
	\\platform="$KAI_ARTIFACTS/kai-platform"
	\\hash="$(basename "$platform"/*.tar.zst .tar.zst)"
	\\cp -RL "$platform/$hash" "$packages/$hash"
	\\url="https://github.com/thebrandonlucas/kai/releases/download"
	\\url="$(printf '"%s/v%s/%s.tar.zst"' "$url" "$(cat VERSION)" "$hash")"
	\\api="api: platform $url"
	\\cp -R plugins/std/. stage
	\\rm -rf stage/*/fuzz stage/backends/*/fuzz
	\\replace() {
	\\  grep -qF "$2" "$1" || { echo "$1 lacks $2" >&2; exit 1; }
	\\  sed -i "s|$2|$3|g" "$1"
	\\}
	\\replace stage/model/main.roc 'api: "../../../platform/api.roc"' "$api"
	\\for main in stage/backends/nix/main.roc stage/backends/guix/main.roc; do
	\\  replace "$main" 'api: "../../../../platform/api.roc"' "$api"
	\\done
	\\replace stage/main.roc '"../../platform/main.roc"' "$url"

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
		# flake.lock's nixpkgs: its zig names the hosts' objects as the 0.0.8
		# bundles have them.
		Packages(
			"default",
			From(
				NixPackages(
					"github:NixOS/nixpkgs/e94cb152ed51bd6e24eb4a41f1460252beb52cd2",
				),
			),
		),
		Environment(
			"build",
			[
				Overlays(["roc"]),
				Tools(
					roc.concat([
						"zig_0_16",
						"zstd",
						"coreutils",
						"findutils",
						"gnugrep",
						"gnused",
						"gnutar",
					]),
				),
			],
		),
		# The Roc package bundles of the platform and the std plugin that a
		# release publishes, as flake.nix builds them.
		Build(
			"kai-platform",
			[
				Use("build"),
				Inputs(roc_inputs),
				Run(["sh", "-c", bundle(platform_script)]),
				Output("bundle"),
			],
		),
		Build(
			"kai-std",
			[
				Use("build"),
				Inputs(roc_inputs),
				Needs(["kai-platform"]),
				Run(["sh", "-c", bundle(std_script)]),
				Output("bundle"),
			],
		),
	]).concat(roc_sources),
)
