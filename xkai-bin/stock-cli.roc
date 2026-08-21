app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "./package.roc",
	parser: "./parser/main.roc",
	std: "../plugins/std/main.roc",
}

import Executor
import kai.Plugin
import parser.Body
import std.StdPlugin

registry = [StdPlugin.plugin]

main! = |args| Executor.run!(args, registry)

# -- TESTS --

std_nix_backend = Plugin.find_backend(StdPlugin.plugin.definition.backends, "nix")

std_shell_command = Plugin.find_command(StdPlugin.plugin.definition.commands, "shell")

std_task_command = Plugin.find_command(StdPlugin.plugin.definition.commands, "run")

std_build_command = Plugin.find_command(StdPlugin.plugin.definition.commands, "build")

std_workflow_command = Plugin.find_command(StdPlugin.plugin.definition.commands, "workflow")

selector_host_config = Str.join_with(
	[
		"shell { packages: [\"top-shell\"] }",
		"environment dev { packages: [\"top-environment\"] }",
		"on linux {",
		"  shell { packages: [\"linux-shell\"] }",
		"  environment dev { packages: [\"linux-environment\"] }",
		"}",
	],
	"\n",
)

expect match (std_shell_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(selector_host_config, command, DefaultBackend(backend), [], LINUX, X64) {
			Ok(Selected(block)) => block.body.contains("linux-shell")
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (std_shell_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(selector_host_config, command, DefaultBackend(backend), [], MACOS, X64) {
			Ok(Selected(block)) => block.body.contains("top-shell")
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (std_shell_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(selector_host_config, command, DefaultBackend(backend), ["dev"], LINUX, X64) {
			Ok(SelectedWithBody({ block, body: _ })) => block.body.contains("linux-environment")
			_ => Bool.False
		}
	_ => Bool.False
}

explicit_fallback_config = Str.join_with(
	[
		"environment dev { packages: [\"hello\"] }",
		"task test { environment: \"dev\" run: [\"true\"] }",
		"build app { environment: dev run: [\"true\"] output: \"app\" }",
		"workflow ci { steps: [] }",
	],
	"\n",
)

qualified_task_config = Str.join_with(
	[
		"environment dev nix { packages: [\"hello\"] }",
		"task test nix { environment: \"dev\" run: [\"true\"] }",
	],
	"\n",
)

qualified_task_unqualified_environment_config = Str.join_with(
	[
		"environment dev { packages: [\"hello\"] }",
		"task test nix { environment: \"dev\" run: [\"true\"] }",
	],
	"\n",
)

qualified_fallback_config = Str.join_with(
	[
		"environment qualified nix { packages: [\"qualified-package\"] }",
		"environment unqualified { packages: [\"unqualified-package\"] }",
		"build app nix { environment: qualified run: [\"true\"] output: \"qualified\" }",
		"build app { environment: unqualified run: [\"true\"] output: \"unqualified\" }",
		"workflow ci nix { steps: [\"run qualified\"] }",
		"workflow ci { steps: [\"run unqualified\"] }",
	],
	"\n",
)

expect match (std_task_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		StdPlugin.select_config(explicit_fallback_config, command, ExplicitBackend(backend), ["test"], LINUX, X64) == Err({
			location: None,
			message: "missing task 'test'",
		})
	_ => Bool.False
}

expect match (std_shell_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		StdPlugin.select_config(explicit_fallback_config, command, ExplicitBackend(backend), ["dev"], LINUX, X64) == Err({
			location: None,
			message: "missing environment 'dev'",
		})
	_ => Bool.False
}

expect match (std_build_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(explicit_fallback_config, command, ExplicitBackend(backend), ["app"], LINUX, X64) {
			Ok(SelectedWithRelated(_)) => Bool.True
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (std_workflow_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(explicit_fallback_config, command, ExplicitBackend(backend), ["ci"], LINUX, X64) {
			Ok(SelectedWithBody(_)) => Bool.True
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (std_task_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(qualified_task_config, command, ExplicitBackend(backend), ["test"], LINUX, X64) {
			Ok(SelectedWithRelated(_)) => Bool.True
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (std_task_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		StdPlugin.select_config(qualified_task_unqualified_environment_config, command, ExplicitBackend(backend), ["test"], LINUX, X64) == Err({
			location: None,
			message: "missing environment 'dev'",
		})
	_ => Bool.False
}

expect match (std_build_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(qualified_fallback_config, command, ExplicitBackend(backend), ["app"], LINUX, X64) {
			Ok(SelectedWithRelated({ block, body: _, related_block, related_body: _ })) =>
				block.body.contains("output: \"qualified\"") and related_block.body.contains("qualified-package")
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (std_workflow_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(qualified_fallback_config, command, ExplicitBackend(backend), ["ci"], LINUX, X64) {
			Ok(SelectedWithBody({ block, body: _ })) => block.body.contains("run qualified")
			_ => Bool.False
		}
	_ => Bool.False
}

related_location_config = "environment dev { packages: [\"hello\"] }\ntask test { environment: \"dev\" run: [\"true\"] }"

expect match (std_task_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		match StdPlugin.select_config(related_location_config, command, DefaultBackend(backend), ["test"], LINUX, X64) {
			Ok(SelectedWithRelated({ block, body: _, related_block, related_body: _ })) =>
				block.location == { byte_offset: 51, column: 12, line: 2 } and
					related_block.location == { byte_offset: 17, column: 18, line: 1 }
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (std_build_command, std_nix_backend) {
	(Ok(command), Ok(backend)) =>
		StdPlugin.select_config("", command, DefaultBackend(backend), [".bad"], LINUX, X64) == Err({
			location: None,
			message: "artifact name must not start with '.'",
		})
	_ => Bool.False
}

backend_collision_config = Str.join_with(
	[
		"environment nix { packages: [\"hello\"] }",
		"task nix { environment: \"nix\" run: [\"true\"] }",
		"build nix { environment: nix run: [\"true\"] output: \"app\" }",
		"workflow nix { steps: [\"run nix\"] }",
	],
	"\n",
)

backend_collision_matches : List(Str), Str -> Bool
backend_collision_matches = |args, expected_command|
	match Plugin.plan_registry(registry, backend_collision_config, args, LINUX, X64) {
		Ok(plan) => plan.backend.name == "nix" and plan.command == expected_command
		_ => Bool.False
	}

expect backend_collision_matches(["shell", "nix"], "shell") and
	backend_collision_matches(["run", "nix"], "run") and
		backend_collision_matches(["build", "nix"], "build") and
			backend_collision_matches(["workflow", "nix"], "workflow")

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

workflow_plan = Plugin.plan_registry(registry, workflow_test_config, ["workflow", "ci"], LINUX, X64)

task_plan = Plugin.plan_registry(registry, workflow_test_config, ["run", "test"], LINUX, X64)

build_plan = Plugin.plan_registry(registry, workflow_test_config, ["build", "app"], LINUX, X64)

expect match (workflow_plan, task_plan, build_plan) {
	(Ok(planned_workflow), Ok(planned_task), Ok(planned_build)) =>
		planned_workflow.actions == [PrintLine("workflow: run test")]
			.concat(planned_task.actions)
			.concat([PrintLine("workflow: build app")])
			.concat(planned_build.actions) and
			planned_workflow.requested_packages == planned_task.requested_packages.concat(planned_build.requested_packages)
	_ => Bool.False
}

expect match Plugin.plan_registry(registry, workflow_test_config, ["ci"], LINUX, X64) {
	Err(UnknownCommand) => Bool.True
	_ => Bool.False
}

expect match Plugin.plan_registry(registry, workflow_test_config, ["workflow", "nix"], LINUX, X64) {
	Ok(named_backend_workflow) =>
		match task_plan {
			Ok(planned_task) => named_backend_workflow.actions == [PrintLine("workflow: run test")].concat(planned_task.actions)
			_ => Bool.False
		}
	_ => Bool.False
}

expect match (
	Plugin.plan_registry(registry, workflow_test_config, ["workflow", "nix", "ci"], LINUX, X64),
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

expect match Plugin.plan_registry(registry, invalid_child_config, ["workflow", "ci"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.command == "build" and diagnostic.message == "missing build 'missing'"
	_ => Bool.False
}

cycle_backend = Plugin.Backend.{
	determinate_system: Plugin.DeterminateSystem.{
		default_package_source: "local",
		driver: NoDriver,
		kind: Custom,
	},
	fallback: NoFallback,
	name: "local",
	required_packages: [],
}

cycle_command = Plugin.Command.{
	argument_policy: NoArguments,
	body: Body.object([]),
	config_block: OptionalConfigBlock("loop"),
	name: "loop",
}

cycle_implementation = Plugin.Implementation.{
	actions: [],
	backend: cycle_backend.name,
	command: cycle_command.name,
	renderer: |_| Ok(
		Plugin.RenderResult.{
			actions: [],
			outputs: [],
			requests: [{ args: ["loop"], status: "loop" }],
			requested_packages: [],
		},
	),
}

cycle_registry = [
	{
		definition: Plugin.Definition.{
			backends: [cycle_backend],
			commands: [cycle_command],
			default_backend: cycle_backend.name,
			implementations: [cycle_implementation],
			name: "cycle",
		},
		select_config: Plugin.select_config,
	},
]

expect match Plugin.plan_registry(cycle_registry, "", ["loop"], LINUX, X64) {
	Err(PlanningFailed(diagnostic)) => diagnostic.message == "plan request cycle detected"
	_ => Bool.False
}

custom_run_command = Plugin.Command.{
	argument_policy: AllowArguments,
	body: Body.object([]),
	config_block: OptionalConfigBlock("custom-run"),
	name: "run",
}

custom_run_implementation = Plugin.Implementation.{
	actions: [],
	backend: cycle_backend.name,
	command: custom_run_command.name,
	renderer: |_| Ok(
		Plugin.RenderResult.{
			actions: [PrintLine("custom run")],
			outputs: [],
			requests: [],
			requested_packages: [],
		},
	),
}

alternate_backend = Plugin.Backend.{
	determinate_system: Plugin.DeterminateSystem.{
		default_package_source: "alternate",
		driver: NoDriver,
		kind: Custom,
	},
	fallback: NoFallback,
	name: "alternate",
	required_packages: [],
}

alternate_run_implementation = Plugin.Implementation.{
	actions: [],
	backend: alternate_backend.name,
	command: custom_run_command.name,
	renderer: |_| Ok(
		Plugin.RenderResult.{
			actions: [PrintLine("alternate run")],
			outputs: [],
			requests: [],
			requested_packages: [],
		},
	),
}

custom_run_definition = |default_backend| Plugin.Definition.{
	backends: [cycle_backend, alternate_backend],
	commands: [custom_run_command],
	default_backend,
	implementations: [custom_run_implementation, alternate_run_implementation],
	name: "custom-run",
}

custom_run_registry = {
	definition: custom_run_definition(cycle_backend.name),
	select_config: Plugin.select_config,
}

backend_selection_cases = [
	{
		args: ["run"],
		expected_action: PrintLine("custom run"),
		expected_backend: cycle_backend.name,
		registry: [custom_run_registry],
	},
	{
		args: ["run"],
		expected_action: PrintLine("alternate run"),
		expected_backend: alternate_backend.name,
		registry: [{ definition: custom_run_definition(alternate_backend.name), select_config: Plugin.select_config }],
	},
	{
		args: ["run", alternate_backend.name],
		expected_action: PrintLine("alternate run"),
		expected_backend: alternate_backend.name,
		registry: [custom_run_registry],
	},
]

expect List.all(
	backend_selection_cases,
	|case|
		match Plugin.plan_registry(case.registry, "", case.args, LINUX, X64) {
			Ok(plan) => plan.backend.name == case.expected_backend and plan.actions == [case.expected_action]
			_ => Bool.False
		},
)

registry_validation_cases = [
	{
		definition: Plugin.Definition.{
			backends: [cycle_backend],
			commands: [custom_run_command],
			default_backend: "unknown",
			implementations: [custom_run_implementation],
			name: "unknown-default",
		},
		expected_message: "default backend 'unknown' is not declared",
		expected_plugin: "unknown-default",
	},
	{
		definition: Plugin.Definition.{
			backends: [cycle_backend, alternate_backend],
			commands: [custom_run_command],
			default_backend: alternate_backend.name,
			implementations: [custom_run_implementation],
			name: "missing-default-implementation",
		},
		expected_message: "command 'run' has no implementation for default backend 'alternate'",
		expected_plugin: "missing-default-implementation",
	},
]

expect List.all(
	registry_validation_cases,
	|case|
		match Plugin.validate_registry([{ definition: case.definition, select_config: Plugin.select_config }]) {
			Err(diagnostic) => diagnostic.message == case.expected_message and diagnostic.plugin == case.expected_plugin
			Ok(_) => Bool.False
		},
)

expect match Plugin.plan_registry(
	[custom_run_registry, StdPlugin.plugin],
	"workflow ci { steps: [\"run test\"] }",
	["workflow", "ci"],
	LINUX,
	X64,
) {
	Ok(plan) => plan.actions == [PrintLine("workflow: run test"), PrintLine("custom run")]
	_ => Bool.False
}
