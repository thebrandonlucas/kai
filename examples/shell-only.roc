app [config] { kai: platform "../platform/config.roc" }

config = [
	Shell({
		name: "shell-only",
		package_list: ["zig"],
	}),
]
