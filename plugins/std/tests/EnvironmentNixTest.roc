# Data-driven tests for ensuring Kaifile creates a valid flake.nix
# for all Kaifiles using the `environment` block
import std.StdPlugin
import util.Check

EnvironmentNixTest := [].{}

# A Kaifile block with `environment` produces a flake that can work with
# `shell`.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    devShells."x86_64-linux".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."x86_64-linux"."hello"
		\\      ];
		\\    };
		\\  };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["shell", "dev"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# A Kaifile block with `environment` produces a flake that works for a `task`.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\}
		\\
		\\task greet {
		\\  environment: "dev"
		\\  run: ["hello"]
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    devShells."x86_64-linux".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."x86_64-linux"."hello"
		\\      ];
		\\    };
		\\  };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["run", "greet"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# Transitivity test:
# Running `kai workflow <workflow>` generates a flake that includes the
# environment used in the workflow's task.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\}
		\\
		\\task greet {
		\\  environment: "dev"
		\\  run: ["hello"]
		\\}
		\\
		\\workflow all {
		\\  steps: ["run greet"]
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    devShells."x86_64-linux".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."x86_64-linux"."hello"
		\\      ];
		\\    };
		\\  };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["workflow", "all"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# Transitivity test:
# Running a service which uses an artifact produced by a build block produces
# a flake which has that build block's referenced environment.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\}
		\\
		\\build app {
		\\  environment: dev
		\\  run: ["touch", "app"]
		\\  output: "app"
		\\}
		\\
		\\service demo {
		\\  artifact: "app"
		\\  secrets: []
		\\  restart: on-failure
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    legacyPackages."x86_64-linux" = ${nixpkgs};
		\\    devShells."x86_64-linux".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."x86_64-linux"."hello"
		\\      ];
		\\    };
		\\  };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["service", "demo"],
		Succeeds([
			WritesExactly({
				contents: expected_file,
				path: ".kai/builds/app/flake.nix",
			}),
		]),
	)
}

# Calling kai machine <machine> on a Kaifile whose `machine` block
# references an environment and creates a machine with the specified
# packages in that environment.
expect {
	kaifile =
		\\environment system {
		\\  packages: ["hello"]
		\\}
		\\
		\\machine box {
		\\  environment: system
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: []
		\\}
	expected_file =
		\\{ pkgs, ... }:
		\\{
		\\  boot.loader.grub.enable = false;
		\\  fileSystems."/" = {
		\\    device = "/dev/root";
		\\    fsType = "auto";
		\\  };
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\    pkgs."hello"
		\\  ];
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "box"],
		Succeeds([
			WritesExactly({
				contents: expected_file,
				path: ".kai/machines/box/machine.nix",
			}),
		]),
	)
}

# An image module receives packages from its environment.
expect {
	kaifile =
		\\environment system {
		\\  packages: ["hello"]
		\\}
		\\
		\\machine box {
		\\  environment: system
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: []
		\\}
	expected_file =
		\\{ pkgs, ... }:
		\\{
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\    pkgs."hello"
		\\  ];
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["image", "box"],
		Succeeds([
			WritesExactly({
				contents: expected_file,
				path: ".kai/images/box/machine.nix",
			}),
		]),
	)
}

# An environment with overlays renders a flake with the overlays applied.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\  overlays: ["github:acme/overlay"]
		\\}
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  inputs.overlay0.url = "github:acme/overlay";
		\\  outputs = inputs@{ nixpkgs, overlay0, ... }:
		\\    let
		\\      pkgs = import nixpkgs {
		\\        system = "x86_64-linux";
		\\        overlays = [
		\\          overlay0.overlays.default
		\\        ];
		\\      };
		\\    in {
		\\      kaiSources = {  };
		\\      legacyPackages."x86_64-linux" = pkgs;
		\\      devShells."x86_64-linux".default = pkgs.mkShell {
		\\        packages = [
		\\              pkgs."hello"
		\\        ];
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
		["shell", "dev"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# Repeated overlays are emitted once in declaration order.
expect {
	kaifile =
		\\environment first {
		\\  packages: []
		\\  overlays: [
		\\    "github:acme/one",
		\\    "github:acme/two",
		\\    "github:acme/one"
		\\  ]
		\\}
		\\
		\\environment second {
		\\  packages: []
		\\  overlays: ["github:acme/two", "github:acme/three"]
		\\}
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  inputs.overlay0.url = "github:acme/one";
		\\  inputs.overlay1.url = "github:acme/two";
		\\  inputs.overlay2.url = "github:acme/three";
		\\  outputs = _: {};
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["update"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# Source blocks are exposed through an environment-generated flake.
expect {
	kaifile =
		\\source project {
		\\  url: "github:acme/project"
		\\}
		\\
		\\environment dev {
		\\  packages: []
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"x86_64-linux\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  inputs."kai-source-project".url = "github:acme/project";
		\\  inputs."kai-source-project".flake = false;
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = { "project" = inputs."kai-source-project"; };
		\\    devShells."x86_64-linux".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\      ];
		\\    };
		\\  };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["shell", "dev"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}

# Environment flakes select the Nix system from the requested host.
expect {
	kaifile =
		\\environment dev {
		\\  packages: ["hello"]
		\\}
	nixpkgs = "nixpkgs.legacyPackages.\"aarch64-darwin\""
	expected_file =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  outputs = inputs@{ nixpkgs, ... }: {
		\\    kaiSources = {  };
		\\    devShells."aarch64-darwin".default = ${nixpkgs}.mkShell {
		\\      packages = [
		\\              nixpkgs."legacyPackages"."aarch64-darwin"."hello"
		\\      ];
		\\    };
		\\  };
		\\}

	Check.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: AARCH64, os: MACOS },
			kaifile,
			workspace_root: ".kai",
		},
		["shell", "dev"],
		Succeeds([
			WritesExactly({ contents: expected_file, path: ".kai/flake.nix" }),
		]),
	)
}
