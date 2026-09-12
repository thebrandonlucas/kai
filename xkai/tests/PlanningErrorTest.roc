# Focused tests for command error presentation.
import kai.Plugin
import util.PlanCheck

PlanningErrorTest := [].{}

# A command without help metadata only shows its planning error.
expect {
	moo_command = Plugin.command_syntax(
		"moo",
		[Plugin.required_argument("message")],
	)
	backend = Plugin.Backend.{
		determinate_system: Plugin.DeterminateSystem.{
			default_package_source: "local",
			driver: NoDriver,
			kind: Custom,
		},
		fallback: NoFallback,
		name: "local",
		required_packages: [],
	}
	moo_plugin = Plugin.Definition.{
		backends: [backend],
		implementations: [
			Plugin.Implementation.{
				backend: "local",
				command: "moo",
				plan: |_| Ok(
					Plugin.BackendCommandPlan.{
						artifacts: [],
						prerequisite_commands: [],
						requested_packages: [],
						steps: [],
					},
				),
				validator: NoValidation,
			},
		],
		name: "moo-test",
		schema: {
			blocks: [],
			commands: [Plugin.command_only(moo_command)],
		},
	}

	PlanCheck.error(
		{
			definitions: [moo_plugin],
			host: { arch: X64, os: LINUX },
			kaifile: "",
			workspace_root: ".kai",
		},
		["moo"],
		"error: moo requires exactly one message argument",
	)
}
