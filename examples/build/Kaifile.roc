# Builds run in a sandbox on a fresh copy of the project and keep only their
# declared output: `kai build wisecow` prints the store path of a wisecow
# script that combines fortune and cowsay.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("build"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay", "fortune"])]),
	Build(
		"wisecow",
		[
			Use("cow"),
			Run([
				"sh",
				"-c",
				"printf '#!%s\\n%s | %s\\n' \"$(command -v sh)\" \"$(command -v fortune)\" "
					.concat("\"$(command -v cowsay)\" > wisecow && chmod +x wisecow"),
			]),
			Output("wisecow"),
			# It reads no project files, so its copy holds none.
			Files([]),
		],
	),
	# A build's tools are its build inputs, so their setup hooks run as in
	# `kai shell`: `kai build zlib-flags` asks pkg-config for zlib's flags.
	Environment("zlib", [Tools(["pkg-config", "zlib"])]),
	Build(
		"zlib-flags",
		[
			Use("zlib"),
			Run(["sh", "-c", "pkg-config --libs zlib > flags"]),
			Output("flags"),
			Files([]),
		],
	),
])
