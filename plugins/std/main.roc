package
	[StdPlugin]
	{
		backends: "./backends/main.roc",
		commands: "./commands/main.roc",
		implementations: "./implementations/main.roc",
		shell_nix: "./implementations/shell-nix/main.roc",
		kai: "../../xkai-bin/package.roc",
		parser: "../../xkai-bin/parser/main.roc",
	}
