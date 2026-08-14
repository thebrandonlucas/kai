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
		"deploy production {",
		"  artifact: app",
		"  to: \"ssh://user@host\"",
		"}",
		"deploy nix {",
		"  artifact: app",
		"  to: \"ssh://nix-user@deploy-host\"",
		"}",
	],
	"\n",
)

workflow_plan = PluginApi.plan_registry(registry, workflow_test_config, ["workflow", "ci"], LINUX, X64)

ci_plan = PluginApi.plan_registry(registry, workflow_test_config, ["ci"], LINUX, X64)

task_plan = PluginApi.plan_registry(registry, workflow_test_config, ["run", "test"], LINUX, X64)

build_plan = PluginApi.plan_registry(registry, workflow_test_config, ["build", "app"], LINUX, X64)

deploy_plan = PluginApi.plan_registry(registry, workflow_test_config, ["deploy", "production"], LINUX, X64)

rollback_plan = PluginApi.plan_registry(registry, workflow_test_config, ["rollback", "production"], LINUX, X64)

expect match (workflow_plan, task_plan, build_plan) {
	(Ok(planned_workflow), Ok(planned_task), Ok(planned_build)) =>
		planned_workflow.actions == [PrintLine("workflow: run test")]
			.concat(planned_task.actions)
			.concat([PrintLine("workflow: build app")])
			.concat(planned_build.actions) and
			planned_workflow.requested_packages == planned_task.requested_packages.concat(planned_build.requested_packages)
	_ => Bool.False
}

expect match (workflow_plan, ci_plan) {
	(Ok(planned_workflow), Ok(planned_ci)) =>
		planned_workflow.actions == planned_ci.actions and
			planned_workflow.requested_packages == planned_ci.requested_packages
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
	PluginApi.plan_registry(registry, workflow_test_config, ["ci", "nix"], LINUX, X64),
	workflow_plan,
) {
	(Ok(explicit_workflow), Ok(explicit_ci), Ok(default_workflow)) =>
		explicit_workflow.actions == default_workflow.actions and explicit_ci.actions == default_workflow.actions
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

expect match PluginApi.plan_registry(registry, invalid_child_config, ["ci"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.command == "build" and diagnostic.message == "missing build 'missing'"
	_ => Bool.False
}

expect match (deploy_plan, build_plan) {
	(Ok(planned_deploy), Ok(planned_build)) =>
		planned_deploy.actions.first() == Ok(PrintLine("deploy: build app")) and
			planned_deploy.actions.drop_first(1).drop_last(2) == planned_build.actions and
				match planned_deploy.actions.drop_first(1 + planned_build.actions.len()) {
					[WriteUtf8(write), Exec(exec)] =>
						write.path == ".kai/deployments/production.sh" and
							write.content.contains("predecessor_owned=1") and
								exec == { args: [".kai/deployments/production.sh"], command: "sh" }
					_ => Bool.False
				}
	_ => Bool.False
}

expect match rollback_plan {
	Ok(planned_rollback) =>
		planned_rollback.command == "rollback" and
			planned_rollback.requested_packages == [] and
				match planned_rollback.actions {
					[WriteUtf8(write), Exec(exec)] =>
						write.path == ".kai/rollbacks/production.sh" and
							write.content.contains("target='user@host'") and
								write.content.contains("predecessor=$predecessors/$current_generation") and
									write.content.contains("rollback_verified=1") and
										write.content.contains("release_lock=0") and
											!write.content.contains("nix copy") and
												exec == { args: [".kai/rollbacks/production.sh"], command: "sh" }
					_ => Bool.False
				}
	_ => Bool.False
}

missing_deploy_build_config = "deploy production { artifact: missing to: \"ssh://user@host\" }"

expect match PluginApi.plan_registry(registry, missing_deploy_build_config, ["deploy", "production"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.command == "build" and diagnostic.message == "missing build 'missing'"
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, missing_deploy_build_config, ["rollback", "production"], LINUX, X64) {
	Ok(plan) => plan.actions.len() == 2 and plan.command == "rollback"
	_ => Bool.False
}

invalid_destination_config = "deploy production { artifact: app to: \"ssh://user@host:22\" }"

expect match PluginApi.plan_registry(registry, invalid_destination_config, ["deploy", "production"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) =>
		diagnostic.command == "deploy" and
			diagnostic.message == "deployment destination must be exactly ssh://user@host with a safe user and hostname"
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, invalid_destination_config, ["rollback", "production"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) =>
		diagnostic.command == "rollback" and
			diagnostic.message == "deployment destination must be exactly ssh://user@host with a safe user and hostname"
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, workflow_test_config, ["deploy", "production"], MACOS, AARCH64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.command == "deploy" and diagnostic.message == "unsupported deployment platform"
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, workflow_test_config, ["rollback", "production"], MACOS, AARCH64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.command == "rollback" and diagnostic.message == "unsupported rollback platform"
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, workflow_test_config, ["deploy", "nix"], LINUX, X64) {
	Ok(plan) =>
		match plan.actions.drop_last(1).last() {
			Ok(WriteUtf8(write)) =>
				write.path == ".kai/deployments/nix.sh" and
					write.content.contains("target='nix-user@deploy-host'")
			_ => Bool.False
		}
	_ => Bool.False
}

expect match PluginApi.plan_registry(registry, workflow_test_config, ["rollback", "nix"], LINUX, X64) {
	Ok(plan) =>
		match plan.actions.first() {
			Ok(WriteUtf8(write)) =>
				write.path == ".kai/rollbacks/nix.sh" and
					write.content.contains("target='nix-user@deploy-host'")
			_ => Bool.False
		}
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
			requests: [{ args: ["loop"], requirement: AnyPlan, status: "loop" }],
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

parent_command = PluginApi.Command.{
	argument_policy: NoArguments,
	body: Body.object([]),
	config_block: OptionalConfigBlock("parent"),
	default_backend: cycle_backend.name,
	name: "parent",
}

parent_implementation = PluginApi.Implementation.{
	actions: [],
	backend: cycle_backend.name,
	command: parent_command.name,
	renderer: |_| Ok(
		PluginApi.RenderResult.{
			actions: [PrintLine("parent action")],
			outputs: [],
			requests: [{ args: ["run"], requirement: AnyPlan, status: "request child" }],
			requested_packages: [],
		},
	),
}

custom_run_registry = {
	definition: PluginApi.Definition.{
		backends: [cycle_backend],
		commands: [custom_run_command, parent_command],
		implementations: [custom_run_implementation, parent_implementation],
		name: "custom-run",
	},
	select_config: PluginApi.select_config,
}

expect match PluginApi.plan_registry(
	[custom_run_registry, StdPlugin.plugin],
	"workflow ci { steps: [\"run test\"] }",
	["ci"],
	LINUX,
	X64,
) {
	Ok(plan) => plan.actions == [PrintLine("workflow: run test"), PrintLine("custom run")]
	_ => Bool.False
}

expect match PluginApi.plan_registry([custom_run_registry], "", ["parent"], LINUX, X64) {
	Ok(plan) => plan.actions == [PrintLine("request child"), PrintLine("custom run"), PrintLine("parent action")]
	_ => Bool.False
}

custom_build_backend = PluginApi.Backend.{
	determinate_system: cycle_backend.determinate_system,
	fallback: cycle_backend.fallback,
	name: "nix",
	required_packages: cycle_backend.required_packages,
}

custom_build_command = PluginApi.Command.{
	argument_policy: AllowArguments,
	body: Body.object([]),
	config_block: OptionalConfigBlock("custom-build"),
	default_backend: custom_build_backend.name,
	name: "build",
}

custom_build_implementation = PluginApi.Implementation.{
	actions: [],
	backend: custom_build_backend.name,
	command: custom_build_command.name,
	renderer: |_| Ok(
		PluginApi.RenderResult.{
			actions: [PrintLine("custom build")],
			outputs: [],
			requests: [],
			requested_packages: [],
		},
	),
}

custom_build_registry = {
	definition: PluginApi.Definition.{
		backends: [custom_build_backend],
		commands: [custom_build_command],
		implementations: [custom_build_implementation],
		name: "custom-build-owner",
	},
	select_config: PluginApi.select_config,
}

expect match PluginApi.plan_registry(
	[custom_build_registry, StdPlugin.plugin],
	workflow_test_config,
	["deploy", "production"],
	LINUX,
	X64,
) {
	Err(PlanningFailed(diagnostic)) =>
		diagnostic.command == "build" and
			diagnostic.plugin == "custom-build-owner" and
				diagnostic.backend == "nix" and
					diagnostic.message == "plan request requires 'std/nix', but child planned from 'custom-build-owner/nix'"
	_ => Bool.False
}
