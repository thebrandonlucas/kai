# Nix implementation for activating a declared machine.
import kai.Plugin
import backends.Nix as NixBackend
import commands.Switch as SwitchCommand

SwitchNix := [].{
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: SwitchCommand.command_syntax.name,
		plan: SwitchNix.plan,
		validator: NoValidation,
	}

	plan = |input| {
		names = Plugin.effective_blocks_of_kind(input, ["machine"]).map(
			|block|
				match block.header {
					["machine", found] | ["machine", found, _] => found
					_ => ""
				},
		)
		name = match names {
			[first, .. as rest] if List.all(rest, |found| found == first) => Ok(first)
			_ => Err({
				byte_offset: None,
				message: "system switch requires exactly one machine",
			})
		}?
		target = match input.command_arguments {
			[] => Ok({ arguments: [], name: "the local machine" })
			[host] =>
				match host.split_on("@") {
					[user, address] if !host.starts_with("-") and
						!user.is_empty() and
							!address.is_empty() => Ok({
						arguments: ["--target-host", host],
						name: "remote host '${host}'",
					})
					_ => Err({
						byte_offset: None,
						message: "switch host must use USER@HOST form",
					})
				}
			_ => Err({
				byte_offset: None,
				message: "switch accepts at most one host",
			})
		}?
		confirmation =
			\\WARNING: This will replace the running system on
			\\${target.name} with machine '${name}' from '${input.kaifile_path}',
			\\restart affected services,
			\\and make it the boot default.
			\\Continue? [y/N]
		Ok({
			artifacts: [],
			prerequisite_commands: [
				{
					arguments: ["machine", NixBackend.backend.name, name],
					description: "switch: machine ${name}",
				},
			],
			requested_packages: [],
			steps: [
				Confirm(confirmation),
				RunProgram({
					arguments: [
						"switch",
						"--flake",
						"path:${input.workspace_root}/machines/${name}#${name}",
						"--no-update-lock-file",
					].concat(target.arguments),
					program: "nixos-rebuild",
				}),
			],
		})
	}
}
