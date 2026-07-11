app [config] { kai: platform "../platform/config.roc" }

config = [
	Shell({
		environment: "./fixtures/shell",
		run: "zig version >/dev/null && printf kai-shell-ok",
	}),
]
