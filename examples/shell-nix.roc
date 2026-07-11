app [config] { kai: platform "../platform/config.roc" }

config = {
	shell: {
		environment: "./fixtures/shell",
		run: "zig version >/dev/null && printf kai-shell-ok",
	},
	machine: {
		build: {
			hostname: "kai-example",
			system: "x86_64-linux",
			install: ["git"],
			ssh_keys: [],
			state_version: "25.05",
			image: { format: "qcow2" },
		},
	},
}
