# A Rust project pins its toolchain in rust-toolchain.toml, which rustup reads
# too. RustToolchain takes the file's text, so the Kaifile does not repeat the
# version; rust-overlay, selected with Overlays, builds the toolchain it pins.
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
	Shell("default", [Use("rust")]),
])
