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
	match input.backend_body {
		NoBackendBody => Err({
			byte_offset: None,
			message: "expected a backend body",
		})
		BackendBody(selected) => {
			offset = U64.to_str(selected.location.byte_offset)
			line = U64.to_str(selected.location.line)
			column = U64.to_str(selected.location.column)
			Ok(
				Plugin.BackendCommandPlan.{
					artifacts: [],
					prerequisite_commands: [],
					requested_packages: [],
					steps: [
						WriteFile({
							contents: "${offset}:${line}:${column}\n${selected.body}",
							path: "captured-backend-body",
						}),
					],
				},
			)
		}
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

# The selected implementation receives only its exact opaque body and its
# absolute source location.
expect {
	kaifile =
		\\escape sample {
		\\  label: "kept"
		\\  backend alpha {unused}
		\\  backend beta {raw { nested } "# }" # comment }
		\\last}
		\\}
	expected =
		\\73:4:17
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
