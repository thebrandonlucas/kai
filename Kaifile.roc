# Kai's own development environment and release builds, on the platform and
# std bundles of the last release.
app [kaifile] {
	pf: platform "https://github.com/thebrandonlucas/kai/releases/download/v0.0.11/65bk6qdahqxn1mm6LR6Hkyw8dSdoeRZGwjNSuiPfvguP.tar.zst",
	std: "https://github.com/thebrandonlucas/kai/releases/download/v0.0.11/std-6Jw5GxNCFkpnvBbnFmQg4KAVEn5bAfEveSZfDSzTDs42.tar.zst",
}

import std.FlakeRef
import std.InputName
import std.Std
import std.Tool

import ".roc-downloads" as roc_downloads : Str
import ".roc-overlay" as roc_overlay : Str
import ".roc-version" as roc_version : Str

# The Roc compiler .roc-version pins, from the roc-overlay .roc-overlay pins,
# as kai itself gets it.
overlay =
	FlakeRef.from_quote(roc_overlay.trim()).map_ok(|ref| [Overlay("roc", ref)])
		?? []

roc = Tool.from_quote("rocpkgs.${roc_version.trim()}").map_ok(|t| [t]) ?? []

# The Roc packages the platform imports (Weaver, which imports ansi and path),
# each named by its hash as Roc caches it.
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

# The packages cli/main.roc adds: basic-cli, which imports http.
cli_packages = [
	(
		"roc-lang/basic-cli/releases/download/0.26.0",
		"GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t",
	),
	(
		"roc-lang/http/releases/download/1.0.0",
		"6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS",
	),
]

inputs = |list| List.keep_oks(list, |(_, name)| InputName.from_quote(name))

roc_inputs = inputs(roc_packages)

roc_sources = List.keep_oks(
	roc_packages.concat(cli_packages),
	|(release, name)| {
		url = "tarball+https://github.com/${release}/${name}.tar.zst"
		Ok(Source(InputName.from_quote(name)?, FlakeRef.from_quote(url)?))
	},
)

# The musl runtime the platform host links with, which platform/build.zig.zon
# also fetches.
link_inputs_tag =
	"link-inputs-sha256-"
		.concat("2df3df339dfb1ad4ae1fad0f382cc100c5b31b3921cdeff939f6aea51457886d")

link_inputs_url =
	"tarball+https://github.com/lukewilliamboswell/roc-platform-template-zig"
		.concat("/releases/download/${link_inputs_tag}/link-inputs-all.tar")

link_inputs = [(link_inputs_url, "link-inputs")]

# Roc's Apple Silicon archive of the nightly .roc-version pins, as
# .roc-downloads names it: Roc links a macOS program against the darwin/
# sysroot only that archive ships, beside its executable.
roc_darwin_archive =
	roc_downloads.split_on("\n").keep_oks(
		|line|
			match line.split_on(" ") {
				["aarch64-darwin", _, _, archive] => Ok(archive)
				_ => Err(OtherSystem)
			},
	).first()
		?? ""

roc_darwin_url =
	"tarball+https://github.com/roc-lang/nightlies/releases/download"
		.concat("/${roc_version.trim()}/${roc_darwin_archive}.tar.gz")

roc_darwin = [(roc_darwin_url, "roc-darwin")]

link_sources = List.keep_oks(
	link_inputs.concat(roc_darwin),
	|(url, name)|
		Ok(Source(InputName.from_quote(name)?, FlakeRef.from_quote(url)?)),
)

# Seeds Roc's package cache with the Inputs.
seed =
	\\set -eu
	\\export XDG_CACHE_HOME="$HOME/.cache" ZIG_GLOBAL_CACHE_DIR="$HOME/zig"
	\\packages="$XDG_CACHE_HOME/roc/packages"
	\\mkdir -p "$packages"
	\\cp -RL "$KAI_INPUTS"/. "$packages/"
	\\

# Runs script to fill stage/ and add packages, and bundles stage/:
# bundle/ holds <hash>.tar.zst, and that unpacked as <hash>/.
bundle = |script|
	seed
		.concat("mkdir stage bundle\n")
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

# zig fetch hands zig build the link_inputs dependency without a network.
platform_script =
	\\(cd platform && zig fetch "$KAI_INPUTS/link-inputs" >/dev/null)
	\\(cd platform && zig build --release)
	\\(cd platform/targets && sha256sum --quiet -c x64musl.sha256 arm64musl.sha256)
	\\mkdir stage/targets
	\\cp platform/*.roc stage/
	\\cp -R platform/targets/*/ stage/targets/

# Fails unless file $1 has $2, and replaces it with $3.
replace_function =
	\\replace() {
	\\  grep -qF "$2" "$1" || { echo "$1 lacks $2" >&2; exit 1; }
	\\  sed -i "s|$2|$3|g" "$1"
	\\}
	\\

# std's own packages reach the platform's modules through api.roc; bundled,
# they depend on the platform itself, by the URL this release publishes it at.
std_script =
	replace_function.concat(
		\\platform="$KAI_ARTIFACTS/kai-platform"
		\\hash="$(basename "$platform"/*.tar.zst .tar.zst)"
		\\cp -RL "$platform/$hash" "$packages/$hash"
		\\url="https://github.com/thebrandonlucas/kai/releases/download"
		\\url="$(printf '"%s/v%s/%s.tar.zst"' "$url" "$(cat VERSION)" "$hash")"
		\\api="api: platform $url"
		\\cp -R plugins/std/. stage
		\\rm -rf stage/*/fuzz stage/backends/*/fuzz
		\\replace stage/model/main.roc 'api: "../../../platform/api.roc"' "$api"
		\\for main in stage/backends/*/main.roc; do
		\\  replace "$main" 'api: "../../../../platform/api.roc"' "$api"
		\\done
		\\replace stage/main.roc '"../../platform/main.roc"' "$url"
	)

# Every other plugin depends on the platform and std by the URLs this release
# publishes them at.
plugin_script = |name|
	replace_function.concat(
		\\base="https://github.com/thebrandonlucas/kai/releases/download"
		\\base="$base/v$(cat VERSION)"
		\\for built in kai-platform kai-std; do
		\\  hash="$(basename "$KAI_ARTIFACTS/$built"/*.tar.zst .tar.zst)"
		\\  cp -RL "$KAI_ARTIFACTS/$built/$hash" "$packages/$hash"
		\\done
		\\bundle() { basename "$KAI_ARTIFACTS/$1"/*.tar.zst; }
		\\pf="$(printf '"%s/%s"' "$base" "$(bundle kai-platform)")"
		\\std="$(printf '"%s/std-%s"' "$base" "$(bundle kai-std)")"
		\\cp -R plugins/${name}/. stage
		\\replace stage/main.roc '"../../platform/main.roc"' "$pf"
		\\replace stage/main.roc '"../std/main.roc"' "$std"
	)

# The bundle, kai-NAME, of plugin NAME other than std that a release
# publishes: one for each plugin devtool/Release.roc's Release.plugins lists.
plugin_build = |build, name|
	Build(
		build,
		[
			Use("build"),
			Inputs(roc_inputs),
			Needs(["kai-platform", "kai-std"]),
			Run(["sh", "-c", bundle(plugin_script(name))]),
			Files(["plugins/${name}", "VERSION"]),
			Output("bundle"),
		],
	)

# The bare kai binary for a Roc target, embedding the URLs this release
# publishes the bundles built here at.
# One Roc worker: the code roc emits depends on how many it uses
# (roc-lang/roc#11449), so a fixed count builds the same binary anywhere.
# Use the default once a Roc nightly emits the same code for any count.
binary_script = |target, prepare, finish|
	seed.concat(prepare).concat(
		\\url="https://github.com/thebrandonlucas/kai/releases/download"
		\\base="$url/v$(cat VERSION)"
		\\bundle() { basename "$KAI_ARTIFACTS/$1"/*.tar.zst; }
		\\echo "$base/$(bundle kai-platform)" > platform-release
		\\echo "$base/std-$(bundle kai-std)" > plugins/std-release
		\\flags="--opt=size --target=${target} --jobs=1"
		\\"$roc" build cli/main.roc $flags --output=kai
		\\
	).concat(finish).concat(
		\\chmod -R u+w "$packages"
		\\mkdir bin
		\\install -m755 kai bin/kai
	)

# A Linux kai, stripped of its symbols.
linux_script = |target|
	binary_script(target, "roc=roc\n", "llvm-strip kai\n")

# The Apple Silicon kai, cross-built: a copy of the Roc compiler with the
# darwin/ sysroot of Roc's macOS archive beside it, where Roc looks for it,
# links it. The Linux archives lack that sysroot; roc-lang/roc#12731, first in
# nightly-2026-10-31-f7bef6b, embeds it in roc, so drop this copy, and the
# roc-darwin source, once .roc-version names that nightly or a later one.
# Not stripped: the linker signs it ad hoc, as macOS requires on Apple
# Silicon, and stripping would rewrite that signature.
darwin_script =
	binary_script(
		"arm64mac",
		\\real="$(readlink -f "$(command -v roc)")"
		\\# roc-overlay wraps the compiler; copy what the wrapper runs.
		\\wrapped="$(dirname "$real")/.roc-wrapped"
		\\if [ -f "$wrapped" ]; then real="$wrapped"; fi
		\\mkdir roc-cross
		\\cp "$real" roc-cross/roc
		\\cp -R "$KAI_INPUTS/roc-darwin/darwin" roc-cross/darwin
		\\roc="$PWD/roc-cross/roc"
		\\
		,
		"",
	)

# What cli/main.roc reads: its modules, the files they embed, and the
# platform, whose api.roc package it imports.
binary_files = [
	"cli",
	"platform",
	"VERSION",
	".roc-version",
	".roc-overlay",
	".roc-downloads",
	"platform-release",
	"plugins/std-release",
]

binary = |name, script, extra_inputs|
	Build(
		name,
		[
			Use("build"),
			Inputs(roc_inputs.concat(inputs(cli_packages)).concat(extra_inputs)),
			Needs(["kai-platform", "kai-std"]),
			Run(["sh", "-c", script]),
			Output("bin"),
			Files(binary_files),
		],
	)

# A release archive of a binary.
release_script =
	\\set -eu
	\\mkdir staging
	\\cp "$KAI_ARTIFACTS"/*/kai staging/kai
	\\chmod 0755 staging/kai
	\\owner="--owner=0 --group=0 --numeric-owner"
	\\tar --sort=name --mtime='UTC 1970-01-01' $owner -czf archive -C staging kai

release = |name, binary_name|
	Build(
		name,
		[
			Use("build"),
			Needs([binary_name]),
			Run(["sh", "-c", release_script]),
			Output("archive"),
			Files([]),
		],
	)

kaifile = Std.kaifile(
	[
		Name("kai"),
		# Apple Silicon Macs get the dev shell; kai build is Linux-only there.
		Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	].concat(overlay).concat([
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
						"shellcheck",
						"sops",
						"unzip",
					]),
				),
			],
		),
		Shell("default", [Use("dev")]),
		# The nixpkgs whose zig names the hosts' objects as the released
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
						"gzip",
						"llvmPackages.bintools-unwrapped",
					]),
				),
			],
		),
		# The Roc package bundles of the platform and the std plugin that a
		# release publishes; the other plugins' are at the end.
		Build(
			"kai-platform",
			[
				Use("build"),
				Inputs(roc_inputs.concat(inputs(link_inputs))),
				Run(["sh", "-c", bundle(platform_script)]),
				Files(["platform"]),
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
				Files(["plugins/std", "VERSION"]),
				Output("bundle"),
			],
		),
		binary("kai-x64musl", linux_script("x64musl"), []),
		binary("kai-arm64musl", linux_script("arm64musl"), []),
		binary("kai-arm64mac", darwin_script, inputs(roc_darwin)),
		release("release-x86-64-linux", "kai-x64musl"),
		release("release-aarch64-linux", "kai-arm64musl"),
		release("release-aarch64-darwin", "kai-arm64mac"),
		plugin_build("kai-guix", "guix"),
		plugin_build("kai-nixos", "nixos"),
		plugin_build("kai-sbom", "sbom"),
	]).concat(roc_sources).concat(link_sources),
)
