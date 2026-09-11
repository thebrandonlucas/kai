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

	checked = Check.compare_planned_write(
		[StdPlugin.plugin],
		{
			args: ["image", "agent"],
			arch: X64,
			kaifile,
			os: LINUX,
			workspace_root: ".kai",
		},
		{
			contents: expected_file,
			path: ".kai/images/agent/flake.nix",
		},
	)
	checked.actual == checked.expected
}

# The image machine module contains environment packages, users, and native
# NixOS services.
# expect {}

# An environment overlay is locked and applied to the image package set.
# expect {}

# A declared Kai service is planned as a prerequisite, copied into the image
# directory, and imported by the image flake.
# expect {}

# Image metadata names the qcow2 output, flake attribute, target architecture,
# and target system.
# expect {}

# Image planning emits the expected build command and output-link path.
# expect {}

# Image planning rejects unsupported hosts and cross-architecture targets.
# expect {}
