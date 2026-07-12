app [config] { kai: platform "../platform/config.roc" }

config = [
	Shell({
		name: "shell-only",
		# `packages` is a Roc header keyword in this compiler, so shell configs use `pkgs`.
		pkgs: ["zig"],
	}),
]
