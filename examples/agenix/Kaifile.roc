# agenix encrypts secrets to the age keys a rules file names. nixpkgs has no
# agenix, so its own flake's overlay adds it. `kai run round-trip` encrypts a
# secret to a throwaway key and decrypts it again.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("agenix"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Overlay("agenix", "github:ryantm/agenix"),
	Environment("secrets", [Tools(["agenix", "age"]), Overlays(["agenix"])]),
	Task("round-trip", [Use("secrets"), Run(["sh", "round-trip.sh"])]),
])
