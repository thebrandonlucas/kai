# Data-driven tests for ensuring Kaifile creates a valid flake.nix
# `kai image <...>` should find the Kaifile block, translate it to
# a flake, which can then create images.
import std.StdPlugin
import util.Check

ImageNixTest := [].{}

# Calling `kai image <machine>` produces the expected image flake.
expect {
	kaifile =
		\\environment server {
		\\  packages: ["curl"]
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: ["agent"]
		\\  services: ["openssh"]
		\\}
	expected_file =
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
		\\          ({ modulesPath, ... }: {
		\\            imports = [
		\\              (modulesPath + "/profiles/qemu-guest.nix")
		\\              (modulesPath + "/virtualisation/disk-image.nix")
		\\            ];
		\\            image.baseName = "agent";
		\\          })
		\\          ./machine.nix
		\\        ];
		\\      };
		\\    in {
		\\      nixosConfigurations."agent" = machine;
		\\      kaiImages."agent" = {
		\\        kind = "machine-image";
		\\        name = "agent";
		\\        format = "qcow2";
		\\        inherit system;
		\\        image = machine.config.system.build.image;
		\\      };
		\\    };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_file,
				path: ".kai/images/agent/flake.nix",
			}),
		]),
	)
}

# The image machine module contains environment packages, users, and native
# NixOS services.
expect {
	kaifile =
		\\environment server {
		\\  packages: ["curl"]
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: ["agent"]
		\\  services: ["openssh"]
		\\}
	expected_file =
		\\{ pkgs, ... }:
		\\{
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\    pkgs."curl"
		\\  ];
		\\  users.users."agent".isNormalUser = true;
		\\  services."openssh".enable = true;
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_file,
				path: ".kai/images/agent/machine.nix",
			}),
		]),
	)
}

# An environment overlay is locked and applied to the image package set.
expect {
	kaifile =
		\\environment server {
		\\  packages: ["curl"]
		\\  overlays: ["github:acme/overlay"]
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: []
		\\}
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  inputs.overlay0.url = "github:acme/overlay";
		\\  outputs = { nixpkgs, overlay0, ... }:
		\\    let
		\\      system = "x86_64-linux";
		\\      pkgs = import nixpkgs {
		\\        inherit system;
		\\        overlays = [
		\\          overlay0.overlays.default
		\\        ];
		\\      };
		\\      machine = nixpkgs.lib.nixosSystem {
		\\        inherit system;
		\\        modules = [
		\\          { nixpkgs.pkgs = pkgs; }
		\\          ({ modulesPath, ... }: {
		\\            imports = [
		\\              (modulesPath + "/profiles/qemu-guest.nix")
		\\              (modulesPath + "/virtualisation/disk-image.nix")
		\\            ];
		\\            image.baseName = "agent";
		\\          })
		\\          ./machine.nix
		\\        ];
		\\      };
		\\    in {
		\\      nixosConfigurations."agent" = machine;
		\\      kaiImages."agent" = {
		\\        kind = "machine-image";
		\\        name = "agent";
		\\        format = "qcow2";
		\\        inherit system;
		\\        image = machine.config.system.build.image;
		\\      };
		\\    };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_file,
				path: ".kai/images/agent/flake.nix",
			}),
		]),
	)
}

# A Kaifile image that includes a service includes the service in the output
# flake
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\build app {
		\\  environment: server
		\\  run: ["touch", "web"]
		\\  output: "web"
		\\}
		\\
		\\service web {
		\\  artifact: "app"
		\\  secrets: []
		\\  restart: on-failure
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: ["web"]
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
		\\          ({ modulesPath, ... }: {
		\\            imports = [
		\\              (modulesPath + "/profiles/qemu-guest.nix")
		\\              (modulesPath + "/virtualisation/disk-image.nix")
		\\            ];
		\\            image.baseName = "agent";
		\\          })
		\\          ./machine.nix
		\\          ./services/web
		\\        ];
		\\      };
		\\    in {
		\\      nixosConfigurations."agent" = machine;
		\\      kaiImages."agent" = {
		\\        kind = "machine-image";
		\\        name = "agent";
		\\        format = "qcow2";
		\\        inherit system;
		\\        image = machine.config.system.build.image;
		\\      };
		\\    };
		\\}
	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_flake,
				path: ".kai/images/agent/flake.nix",
			}),
			ContainsStep(
				RunProgram({
					arguments: [
						"-RH",
						"--preserve=mode",
						"--",
						".kai/artifacts/.services/web",
						".kai/images/agent/services/web",
					],
					program: "cp",
				}),
			),
		]),
	)
}

# Image metadata is invalidated before the exact final metadata is written.
expect {
	kaifile =
		\\environment server {
		\\  packages: ["curl"]
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: ["agent"]
		\\  services: ["openssh"]
		\\}
	expected_metadata = Str.join_with(
		[
			"{\"backend\":\"nix\",",
			"\"flake_attribute\":\"kaiImages.\\\"agent\\\".image\",",
			"\"flake_path\":\".kai/images/agent\",",
			"\"format\":\"qcow2\",\"kind\":\"machine-image\",",
			"\"metadata_path\":\".kai/artifacts/images/agent/metadata.json\",",
			"\"name\":\"agent\",",
			"\"output_path\":\".kai/artifacts/images/agent/result/agent.qcow2\",",
			"\"schema\":1,\"target_architecture\":\"x86_64\",",
			"\"target_system\":\"x86_64-linux\"}",
		],
		"",
	)
	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "agent"],
		Succeeds([
			WritesAtPathExactly({
				contents: ["", expected_metadata],
				path: ".kai/artifacts/images/agent/metadata.json",
			}),
		]),
	)
}

# Image planning emits the expected build command and output-link path.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: []
		\\}
	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "agent"],
		Succeeds([
			ContainsStep(
				RunProgram({
					arguments: [
						"build",
						"path:.kai/images/agent#kaiImages.\"agent\".image",
						"--no-update-lock-file",
						"--out-link",
						".kai/artifacts/images/agent/result",
					],
					program: "nix",
				}),
			),
		]),
	)
}

# Image planning rejects unsupported hosts and targets.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: []
		\\}
	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: MACOS },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "image",
				location: None,
				message: "NixOS machine builds are supported only on Linux hosts",
				plugin: "std",
			}),
		),
	) and
		Check.plan(
			{
				definitions: [StdPlugin.plugin],
				host: { arch: AARCH64, os: LINUX },
				kaifile,
				workspace_root: ".kai",
			},
			["image", "agent"],
			FailsWith(
				PlanningFailed({
					backend: "nix",
					command: "image",
					location: None,
					message: Str.join_with(
						[
							"cross-architecture NixOS machine builds are not supported; ",
							"target 'x86_64-linux' must match the host architecture",
						],
						"",
					),
					plugin: "std",
				}),
			),
		)
}
