# A CargoVendor vendors the crates Cargo.lock names, pinned by its checksums
# and, for the git dependency ryu, by the commit it records, with no lock
# entry. So `kai build count` compiles this crate offline in the sandbox:
# cargo reads the crates from $KAI_INPUTS/crates through the configuration
# vendored with them.
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
				"cargo build --release --offline --locked "
					.concat("--config \"$KAI_INPUTS/crates/.cargo/config.toml\" ")
					.concat("&& target/release/count > count.txt"),
			]),
			Output("count.txt"),
		],
	),
])
