# Nix implementation for deploying a declared machine.
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import commands.Deploy as DeployCommand

DeployNix := [].{
	DeclaredTarget := { host : Str, machine : Str }

	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: DeployCommand.command_syntax.name,
		plan: DeployNix.plan,
		validator: NoValidation,
	}

	declared_target :
		List(Str),
		Fields.ParsedFields ->
			Try(
				DeclaredTarget,
				Plugin.BackendPlanningDiagnostic,
			)
	declared_target = |arguments, fields| {
		machine = match arguments {
			[selected] => Ok(selected)
			_ => Err({
				byte_offset: None,
				message: "deploy requires exactly one machine",
			})
		}?
		host = Fields.get_string(fields, "target") ? |_|
			{
				byte_offset: None,
				message: "machine '${machine}' must declare 'target' to deploy",
			}
		Ok(DeployNix.DeclaredTarget.{ host, machine })
	}

	target_failures : Str -> List(Str)
	target_failures = |target|
		match target.split_on("@") {
			["root", host] if !host.is_empty() and
				!host.starts_with("-") and
					List.all(host.to_utf8(), DeployNix.valid_host_byte) => []
			_ => ["machine target must use root@HOST with a valid SSH host"]
		}

	valid_host_byte : U8 -> Bool
	valid_host_byte = |byte|
		(byte >= 48 and byte <= 57) or
			(byte >= 65 and byte <= 90) or
				(byte >= 97 and byte <= 122) or
					['%', '-', '.', ':', '[', ']', '_'].contains(byte)

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		selection = DeployNix.declared_target(
			input.command_arguments,
			input.command_fields,
		)?
		Plugin.implementation_validation(
			DeployNix.target_failures(selection.host),
		)?
		flake_path = Plugin.workspace_path(
			input.workspace_root,
			"machines/${selection.machine}",
		)
		Ok({
			artifacts: [],
			prerequisite_commands: [
				{
					arguments: ["machine", NixBackend.backend.name, selection.machine],
					description: "deploy: machine ${selection.machine}",
				},
			],
			requested_packages: [],
			steps: [
				Confirm(
					"Deploy '${selection.machine}' to '${selection.host}'? [y/N]",
				),
				RunProgram({
					arguments: [
						"switch",
						"--flake",
						"path:${flake_path}#${selection.machine}",
						"--no-update-lock-file",
						"--target-host",
						selection.host,
					],
					program: "nixos-rebuild",
				}),
			],
		})
	}
}
