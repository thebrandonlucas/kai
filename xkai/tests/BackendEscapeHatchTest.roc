# Focused planner fixture for opaque backend declaration bodies.
import kai.Kaifile
import kai.Plugin
import util.PlanCheck

BackendEscapeHatchTest := [].{}

backend = |name|
	Plugin.Backend.{
		determinate_system: Plugin.DeterminateSystem.{
			default_package_source: "local",
			driver: NoDriver,
			kind: Custom,
		},
		fallback: NoFallback,
		name,
		required_packages: [],
	}

block = Kaifile.named_block({
	fields: [Kaifile.required("label", String)],
	header: "escape <name>",
	name_rules: [],
})

command = Plugin.command_with_block({
	block,
	syntax: Plugin.command_syntax(
		"escape",
		[Plugin.required_argument("name")],
	),
})

capture_plan = |input|
	match (input.backend_config, input.backend_body) {
		(NoBackendBody, _) => Err({
			byte_offset: None,
			message: "expected a backend configuration",
		})
		(_, NoBackendBody) => Err({
			byte_offset: None,
			message: "expected a backend body",
		})
		(BackendBody(config), BackendBody(selected)) => {
			config_offset = U64.to_str(config.location.byte_offset)
			config_line = U64.to_str(config.location.line)
			config_column = U64.to_str(config.location.column)
			offset = U64.to_str(selected.location.byte_offset)
			line = U64.to_str(selected.location.line)
			column = U64.to_str(selected.location.column)
			contents = Str.join_with(
				[
					"${config_offset}:${config_line}:${config_column}",
					config.body,
					"---",
					"${offset}:${line}:${column}",
					selected.body,
				],
				"\n",
			)
			Ok(
				Plugin.BackendCommandPlan.{
					artifacts: [],
					prerequisite_commands: [],
					requested_packages: [],
					steps: [
						WriteFile({ contents, path: "captured-backend-body" }),
					],
				},
			)
		}
		_ => Err({
			byte_offset: None,
			message: "invalid backend selections",
		})
	}

implementation = |backend_name|
	Plugin.Implementation.{
		backend: backend_name,
		command: "escape",
		plan: capture_plan,
		validator: NoValidation,
	}

definition = Plugin.Definition.{
	backends: [backend("alpha"), backend("beta")],
	implementations: [implementation("alpha"), implementation("beta")],
	name: "backend-escape-hatch-test",
	schema: {
		blocks: [block],
		commands: [command],
	},
}

# Global configuration stays separate from the selected command's opaque body,
# and both preserve their absolute source locations.
expect {
	kaifile =
		\\backend beta {global}
		\\
		\\escape sample {
		\\  label: "kept"
		\\  backend alpha {unused}
		\\  backend beta {raw { nested } "# }" # comment }
		\\last}
		\\}
	expected =
		\\14:1:15
		\\global
		\\---
		\\96:6:17
		\\raw { nested } "# }" # comment }
		\\last

	PlanCheck.plan(
		{
			definitions: [definition],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["escape", "beta", "sample"],
		Succeeds([
			WritesExactly({
				contents: expected,
				path: "captured-backend-body",
			}),
		]),
	)
}

# More than one top-level backend configuration is rejected.
expect {
	kaifile =
		\\backend alpha {first}
		\\backend beta {second}
		\\escape sample {
		\\  label: "kept"
		\\  backend alpha {local}
		\\}

	PlanCheck.plan(
		{
			definitions: [definition],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["escape", "alpha", "sample"],
		FailsWith(
			PlanningFailed({
				backend: "alpha",
				command: "escape",
				location: At({ byte_offset: 36, column: 15, line: 2 }),
				message: "only one top-level backend block is allowed",
				plugin: "backend-escape-hatch-test",
			}),
		),
	)
}

# A top-level configuration must name a backend registered by the plugin.
expect {
	kaifile =
		\\backend unknown {config}
		\\escape sample {
		\\  label: "kept"
		\\  backend alpha {local}
		\\}

	PlanCheck.plan(
		{
			definitions: [definition],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["escape", "alpha", "sample"],
		FailsWith(
			PlanningFailed({
				backend: "alpha",
				command: "escape",
				location: At({ byte_offset: 17, column: 18, line: 1 }),
				message: "backend configuration references unknown backend 'unknown'",
				plugin: "backend-escape-hatch-test",
			}),
		),
	)
}
