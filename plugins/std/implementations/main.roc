package
	[
		BuildNix,
		EnvironmentNix,
		ImageNix,
		MachineNix,
		ServiceNix,
		ShellNix,
		ShellNixValidation,
		TaskNix,
		UpdateNix,
		WorkflowNix,
	]
	{
		backends: "../backends/main.roc",
		commands: "../commands/main.roc",
		kai: "../../../xkai/package.roc",
		parser: "../../../xkai/parser/main.roc",
		project_configs: "../project_configs/main.roc",
	}
