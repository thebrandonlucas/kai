app [config] { kai: platform "../platform/config.roc" }

config = [
	Shell({
		install: ["zig"],
		run: "zig version >/dev/null && printf kai-shell-ok",
	}),
]
