app [config] { kai: platform "../platform/config.roc" }

config = {
	shell: {
		environment: "./fixtures/shell",
		run: "zig version >/dev/null && printf kai-shell-ok",
	},
	stdout: "kai-shell-ok",
}
