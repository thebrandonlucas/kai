app [config] { kai: platform "../platform/config.roc" }

config = [
	Shell({
		name: "shell-example",
		# `packages` is a Roc header keyword in this compiler, so shell configs use `pkgs`.
		pkgs: ["zig"],
	}),
	MachineBuild({
		hostname: "kai-example",
		system: "x86_64-linux",
		install: ["git"],
		ssh_keys: [],
		state_version: "25.05",
		image: { format: "qcow2" },
	}),
]
