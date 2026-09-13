# Planning `kai iso <machine>` produces a bootable ISO artifact.
import std.StdPlugin
import util.PlanCheck

IsoNixTest := [].{}

expect {
	kaifile =
		\\environment recovery {
		\\  packages: ["curl"]
		\\}
		\\
		\\machine rescue {
		\\  environment: recovery
		\\  system: "x86_64-linux"
		\\  users: ["admin"]
		\\  services: ["openssh"]
		\\}
	expected_flake =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = { nixpkgs, ... }:
		\\    let
		\\      system = "x86_64-linux";
		\\      pkgs = import nixpkgs {
		\\        inherit system;
		\\        overlays = [
		\\        ];
		\\      };
		\\      machine = nixpkgs.lib.nixosSystem {
		\\        inherit system;
		\\        modules = [
		\\          { nixpkgs.pkgs = pkgs; }
		\\          ({ lib, modulesPath, ... }: {
		\\            imports = [
		\\              (modulesPath + "/installer/cd-dvd/"
		\\                + "installation-cd-minimal.nix")
		\\            ];
		\\            image.baseName = lib.mkForce "rescue";
		\\          })
		\\          ./machine.nix
		\\        ];
		\\      };
		\\    in {
		\\      nixosConfigurations."rescue" = machine;
		\\      kaiIsos."rescue" = machine.config.system.build.isoImage;
		\\    };
		\\}
	expected_module =
		\\{ pkgs, ... }:
		\\{
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\    pkgs."curl"
		\\  ];
		\\  users.users."admin".isNormalUser = true;
		\\  services."openssh".enable = true;
		\\}
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["iso", "rescue"],
		Succeeds([
			WritesExactly({
				contents: expected_flake,
				path: ".kai/isos/rescue/flake.nix",
			}),
			WritesExactly({
				contents: expected_module,
				path: ".kai/isos/rescue/machine.nix",
			}),
			ContainsArtifact({
				attributes: [{ key: "format", value: "iso" }],
				kind: "kai.machine.iso/v1",
				name: "rescue",
				path: ".kai/artifacts/isos/rescue/result/iso/rescue.iso",
			}),
			ContainsStep(
				RunProgram({
					arguments: [
						"build",
						"path:.kai/isos/rescue#kaiIsos.\"rescue\"",
						"--no-update-lock-file",
						"--out-link",
						".kai/artifacts/isos/rescue/result",
					],
					program: "nix",
				}),
			),
		]),
	)
}
