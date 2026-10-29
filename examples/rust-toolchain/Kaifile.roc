# A Rust project pins its toolchain in rust-toolchain.toml, which rustup reads
# too. RustToolchain takes the file's text, so the Kaifile does not repeat the
# version; rust-overlay, selected with Overlays, builds the toolchain it pins.
# RustToolchainWith adds components and targets that only Kai's environment
# needs, leaving the file to what every contributor's rustup installs.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

import "rust-toolchain.toml" as toolchain : Str

kaifile = Std.kaifile([
	Name("rust-toolchain"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Overlay("rust", "github:oxalica/rust-overlay"),
	Environment("rust", [RustToolchain(toolchain), Overlays(["rust"])]),
	Environment(
		"wasm",
		[
			Extend("rust"),
			RustToolchainWith(
				toolchain,
				[Components(["clippy"]), Targets(["wasm32-unknown-unknown"])],
			),
		],
	),
	Shell("default", [Use("rust")]),
	Shell("wasm", [Use("wasm")]),
	# Fails unless the wasm32 standard library is installed.
	Task(
		"wasm-target",
		[
			Use("wasm"),
			Run([
				"sh",
				"-c",
				"test -d \"$(rustc --print sysroot)/lib/rustlib/"
					.concat("wasm32-unknown-unknown\""),
			]),
		],
	),
])
