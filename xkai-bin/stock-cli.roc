app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "./package.roc",
	parser: "./parser/main.roc",
	std: "../plugins/main.roc",
}

import Executor
import kai.Plugin as PluginApi
import parser.Body
import std.StdPlugin

registry = [StdPlugin.plugin]

main! = |args| Executor.run!(args, registry)

# -- TESTS --

workflow_test_config = Str.join_with(
	[
		"environment dev {",
		"  packages: [\"hello\"]",
		"}",
		"task test {",
		"  environment: \"dev\"",
		"  run: [\"true\"]",
		"}",
		"build app {",
		"  environment: dev",
		"  run: [\"true\"]",
		"  output: \"app\"",
		"}",
		"workflow ci {",
		"  steps: [\"run test\", \"build app\"]",
		"}",
		"workflow nix {",
		"  steps: [\"run test\"]",
		"}",
	],
	"\n",
)

workflow_plan = PluginApi.plan_registry(registry, workflow_test_config, ["workflow", "ci"], LINUX, X64)

task_plan = PluginApi.plan_registry(registry, workflow_test_config, ["run", "test"], LINUX, X64)

build_plan = PluginApi.plan_registry(registry, workflow_test_config, ["build", "app"], LINUX, X64)

expect match (workflow_plan, task_plan, build_plan) {
	(Ok(planned_workflow), Ok(planned_task), Ok(planned_build)) =>
		planned_workflow.actions == [PrintLine("workflow: run test")]
			.concat(planned_task.actions)
			.concat([PrintLine("workflow: build app")])
			.concat(planned_build.actions) and
			planned_workflow.requested_packages == planned_task.requested_packages.concat(planned_build.requested_packages)
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, workflow_test_config, ["ci"], LINUX, X64) {
	Err(UnknownCommand) => Bool.True
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, workflow_test_config, ["workflow", "nix"], LINUX, X64) {
	Ok(named_backend_workflow) =>
		match task_plan {
			Ok(planned_task) => named_backend_workflow.actions == [PrintLine("workflow: run test")].concat(planned_task.actions)
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (
	PluginApi.plan_registry(registry, workflow_test_config, ["workflow", "nix", "ci"], LINUX, X64),
	workflow_plan,
) {
	(Ok(explicit_workflow), Ok(default_workflow)) => explicit_workflow.actions == default_workflow.actions
	_ => Bool.False
}

invalid_child_config = Str.join_with(
	[
		"environment dev { packages: [\"hello\"] }",
		"task test { environment: \"dev\" run: [\"true\"] }",
		"workflow ci { steps: [\"run test\", \"build missing\"] }",
	],
	"\n",
)

expect match PluginApi.plan_registry(registry, invalid_child_config, ["workflow", "ci"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.command == "build" and diagnostic.message == "missing build 'missing'"
	_ => Bool.False
}

cycle_backend = PluginApi.Backend.{
	determinate_system: PluginApi.DeterminateSystem.{
		default_package_source: "local",
		driver: NoDriver,
		kind: Custom,
	},
	fallback: NoFallback,
	name: "local",
	required_packages: [],
}

cycle_command = PluginApi.Command.{
	argument_policy: NoArguments,
	body: Body.object([]),
	config_block: OptionalConfigBlock("loop"),
	default_backend: cycle_backend.name,
	name: "loop",
}

cycle_implementation = PluginApi.Implementation.{
	actions: [],
	backend: cycle_backend.name,
	command: cycle_command.name,
	renderer: |_| Ok(
		PluginApi.RenderResult.{
			actions: [],
			outputs: [],
			requests: [{ args: ["loop"], status: "loop" }],
			requested_packages: [],
		},
	),
}

cycle_registry = [
	{
		definition: PluginApi.Definition.{
			backends: [cycle_backend],
			commands: [cycle_command],
			implementations: [cycle_implementation],
			name: "cycle",
		},
		select_config: PluginApi.select_config,
	},
]

expect match PluginApi.plan_registry(cycle_registry, "", ["loop"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.message == "plan request cycle detected"
	_ => Bool.False
}

custom_run_command = PluginApi.Command.{
	argument_policy: AllowArguments,
	body: Body.object([]),
	config_block: OptionalConfigBlock("custom-run"),
	default_backend: cycle_backend.name,
	name: "run",
}

custom_run_implementation = PluginApi.Implementation.{
	actions: [],
	backend: cycle_backend.name,
	command: custom_run_command.name,
	renderer: |_| Ok(
		PluginApi.RenderResult.{
			actions: [PrintLine("custom run")],
			outputs: [],
			requests: [],
			requested_packages: [],
		},
	),
}

custom_run_registry = {
	definition: PluginApi.Definition.{
		backends: [cycle_backend],
		commands: [custom_run_command],
		implementations: [custom_run_implementation],
		name: "custom-run",
	},
	select_config: PluginApi.select_config,
}

expect match PluginApi.plan_registry(
	[custom_run_registry, StdPlugin.plugin],
	"workflow ci { steps: [\"run test\"] }",
	["workflow", "ci"],
	LINUX,
	X64,
) {
	Ok(plan) => plan.actions == [PrintLine("workflow: run test"), PrintLine("custom run")]
	_ => Bool.False
}
