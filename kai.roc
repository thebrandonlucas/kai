app [config] { kai: platform "./platform/config.roc" }

config = [
	Shell({
		install: ["zig"],
		run: "zig version >/dev/null && printf kai-shell-ok",
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
