## Kai's standard plugin: environments, shells, tasks, builds and workflows.
package
	[
		Config,
		EnvName,
		FlakeRef,
		InputName,
		Std,
		StdModel,
		System,
		TaskName,
		Tool,
		Val,
		WorkflowName,
	]
	{
		direct: "backends/direct/main.roc",
		model: "model/main.roc",
		nix: "backends/nix/main.roc",
		pf: platform "../../platform/main.roc",
	}

import Std
import pf.Conformance

# Std.roc's planning tests cover every implementation.
expect {
	cases = ["shell", "run", "build", "workflow", "update"]
		.join_map(
			|command| ["nix", "direct"].map(|backend| { command, backend }),
		)
		.append({ command: "model", backend: "" })
		.append({ command: "spec", backend: "" })
		.append({ command: "requirements", backend: "" })
		.append({ command: "lock", backend: "" })
	Conformance.missing(Std.plugin([Name("x")]), cases) == []
}
