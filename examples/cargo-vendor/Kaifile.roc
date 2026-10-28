# A CargoVendor vendors the crates Cargo.lock names, pinned by its checksums
# with no lock entry, so `kai build count` compiles this crate offline in the
# sandbox: cargo reads the crates from $KAI_INPUTS/crates in place of
# crates.io.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std
import "Cargo.lock" as cargo_lock : Str

kaifile = Std.kaifile([
	Name("cargo-vendor"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	CargoVendor("crates", cargo_lock),
	Environment("rust", [Tools(["cargo", "rustc"])]),
	Build(
		"count",
		[
			Use("rust"),
			Inputs(["crates"]),
			Run([
				"sh",
				"-c",
				"cargo build --release --offline "
					.concat("--config 'source.crates-io.replace-with=\"vendored\"' ")
					.concat("--config \"source.vendored.directory='$KAI_INPUTS/crates'\" ")
					.concat("&& target/release/count > count.txt"),
			]),
			Output("count.txt"),
		],
	),
])
