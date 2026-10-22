## Kai's standard plugin: environments, shells, tasks, builds and workflows.
package
	[
		Config,
		EnvName,
		FlakeRef,
		InputName,
		Std,
		System,
		TaskName,
		Tool,
		Val,
		WorkflowName,
	]
	{
		guix: "backends/guix/main.roc",
		model: "model/main.roc",
		nix: "backends/nix/main.roc",
		pf: platform "../../platform/main.roc",
	}
