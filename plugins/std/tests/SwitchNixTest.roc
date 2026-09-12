# Pure planning tests for local and remote system activation.
import std.StdPlugin
import util.PlanCheck

SwitchNixTest := [].{}

expect {
	kaifile =
		\\environment base {
		\\  packages: []
		\\}
		\\machine server {
		\\  environment: base
		\\  system: "x86_64-linux"
		\\}
		\\on macos {
		\\  machine laptop {
		\\    environment: base
		\\    system: "x86_64-linux"
		\\  }
		\\}
	confirmation =
		\\WARNING: This will replace the running system on
		\\the local machine with machine 'server' from 'Kaifile',
		\\restart affected services,
		\\and make it the boot default.
		\\Continue? [y/N]
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["system", "switch"],
		Succeeds([
			ContainsStepsInOrder([
				RunProgram({
					arguments: [
						"build",
						"path:.kai/machines/server#kaiMachines.\"server\".closure",
						"--no-update-lock-file",
						"--out-link",
						".kai/artifacts/machines/server/closure",
					],
					program: "nix",
				}),
				Confirm(confirmation),
				RunProgram({
					arguments: [
						"switch",
						"--flake",
						"path:.kai/machines/server#server",
						"--no-update-lock-file",
					],
					program: "nixos-rebuild",
				}),
			]),
		]),
	)
}

expect {
	kaifile =
		\\environment base {
		\\  packages: []
		\\}
		\\machine server {
		\\  environment: base
		\\  system: "x86_64-linux"
		\\}
	confirmation =
		\\WARNING: This will replace the running system on
		\\remote host 'root@example.com' with machine 'server' from 'Kaifile',
		\\restart affected services,
		\\and make it the boot default.
		\\Continue? [y/N]
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["system", "switch", "root@example.com"],
		Succeeds([
			ContainsStepsInOrder([
				Confirm(confirmation),
				RunProgram({
					arguments: [
						"switch",
						"--flake",
						"path:.kai/machines/server#server",
						"--no-update-lock-file",
						"--target-host",
						"root@example.com",
					],
					program: "nixos-rebuild",
				}),
			]),
		]),
	)
}
