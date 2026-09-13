# Pure planning tests for deploying a declared machine.
import std.StdPlugin
import util.PlanCheck

DeployNixTest := [].{}

# Deploy builds the machine before confirming and activating it remotely.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\machine production {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  target: "root@server.example.com"
		\\}
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["deploy", "production"],
		Succeeds([
			ContainsStepsInOrder([
				RunProgram({
					arguments: [
						"build",
						"path:.kai/machines/production#kaiMachines.\"production\".closure",
						"--no-update-lock-file",
						"--out-link",
						".kai/artifacts/machines/production/closure",
					],
					program: "nix",
				}),
				Confirm("Deploy 'production' to 'root@server.example.com'? [y/N]"),
				RunProgram({
					arguments: [
						"switch",
						"--flake",
						"path:.kai/machines/production#production",
						"--no-update-lock-file",
						"--target-host",
						"root@server.example.com",
					],
					program: "nixos-rebuild",
				}),
			]),
		]),
	)
}

# Deploy rejects a machine without a declared SSH target.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\machine production {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\}
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["deploy", "production"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "deploy",
				location: None,
				message: "machine 'production' must declare 'target' to deploy",
				plugin: "std",
			}),
		),
	)
}

# Deploy rejects a target without the required root SSH user.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\machine production {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  target: "server.example.com"
		\\}
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["deploy", "production"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "deploy",
				location: None,
				message: "machine target must use root@HOST with a valid SSH host",
				plugin: "std",
			}),
		),
	)
}
