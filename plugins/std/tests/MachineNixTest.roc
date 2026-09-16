# Data-driven tests for ensuring `kai machine <...>` translates a machine
# block into a flake
import std.StdPlugin
import util.PlanCheck

MachineNixTest := [].{}

# A machine renders a flake and NixOS module with its overlay, packages, users,
# and native NixOS services.
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
		\\  users: ["agent"]
		\\  services: ["openssh"]
		\\}
	expected_flake =
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
		\\          ./machine.nix
		\\        ];
		\\      };
		\\    in {
		\\      nixosConfigurations."agent" = machine;
		\\      kaiMachines."agent" = {
		\\        kind = "machine";
		\\        name = "agent";
		\\        inherit system;
		\\        closure = machine.config.system.build.toplevel;
		\\      };
		\\    };
		\\}
	expected_module =
		\\{ pkgs, ... }:
		\\{
		\\  boot.loader.grub.enable = false;
		\\  fileSystems."/" = {
		\\    device = "/dev/root";
		\\    fsType = "auto";
		\\  };
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\    pkgs."curl"
		\\  ];
		\\  users.users."agent".isNormalUser = true;
		\\  services."openssh".enable = true;
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_flake,
				path: ".kai/machines/agent/flake.nix",
			}),
			WritesExactly({
				contents: expected_module,
				path: ".kai/machines/agent/machine.nix",
			}),
		]),
	)
}

# Backend Nix assignments render every supported scalar and quote option paths.
expect {
	dollar = "$"
	json_backspace = "\\b"
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
		\\  backend nix {
		\\    services.demo-name.enable: true
		\\    services.demo-name.disabled: false
		\\    services.demo-name.retries: -12
		\\    services.demo-name.minimum: -9223372036854775808
		\\    services.demo-name.maximum: 9223372036854775807
		\\    services.demo-name.message: "quote: \\" slash: \\\\ ${dollar}{pkgs}"
		\\    services.demo-name.ctrl: "${json_backspace}"
		\\    services.demo-name.values: [true, -2, 3, "four"]
		\\    services.demo-name.empty: []
		\\  }
		\\}
	minimum = "-9223372036854775808"
	message = "\"quote: \\\" slash: \\\\ \\${dollar}{pkgs}\""
	expected_module =
		\\{ pkgs, ... }:
		\\{
		\\  boot.loader.grub.enable = false;
		\\  fileSystems."/" = {
		\\    device = "/dev/root";
		\\    fsType = "auto";
		\\  };
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\  ];
		\\  imports = [
		\\    {
		\\      "services"."demo-name"."enable" = true;
		\\      "services"."demo-name"."disabled" = false;
		\\      "services"."demo-name"."retries" = (-12);
		\\      "services"."demo-name"."minimum" = (builtins.fromJSON "${minimum}");
		\\      "services"."demo-name"."maximum" = 9223372036854775807;
		\\      "services"."demo-name"."message" = ${message};
		\\      "services"."demo-name"."ctrl" = (builtins.fromJSON "\\\"\\\\b\\\"");
		\\      "services"."demo-name"."values" = [ true (-2) 3 "four" ];
		\\      "services"."demo-name"."empty" = [  ];
		\\    }
		\\  ];
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_module,
				path: ".kai/machines/agent/machine.nix",
			}),
		]),
	)
}

# Duplicate backend option paths are rejected at the second assignment.
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
		\\  backend nix {
		\\    services.demo.enable: true
		\\    services.demo.enable: false
		\\  }
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "machine",
				location: At({ byte_offset: 180, column: 5, line: 12 }),
				message: "duplicate NixOS option path 'services.demo.enable'",
				plugin: "std",
			}),
		),
	)
}

# Backend option paths reject empty dotted segments.
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
		\\  backend nix {
		\\    services..demo.enable: true
		\\  }
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "machine",
				location: At({ byte_offset: 149, column: 5, line: 11 }),
				message: "NixOS option path must contain nonempty dotted segments",
				plugin: "std",
			}),
		),
	)
}

# Backend option assignments must be separated after strings and lists.
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
		\\  backend nix {
		\\    services.demo.message: "hello"services.demo.enable: true
		\\  }
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "machine",
				location: At({ byte_offset: 179, column: 35, line: 11 }),
				message: "expected whitespace between NixOS option assignments",
				plugin: "std",
			}),
		),
	)
}

# A declared Kai service is built first, copied into the machine directory,
# and imported instead of being enabled as a native NixOS service.
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
		\\          ./machine.nix
		\\          ./services/web
		\\        ];
		\\      };
		\\    in {
		\\      nixosConfigurations."agent" = machine;
		\\      kaiMachines."agent" = {
		\\        kind = "machine";
		\\        name = "agent";
		\\        inherit system;
		\\        closure = machine.config.system.build.toplevel;
		\\      };
		\\    };
		\\}
	expected_module =
		\\{ pkgs, ... }:
		\\{
		\\  boot.loader.grub.enable = false;
		\\  fileSystems."/" = {
		\\    device = "/dev/root";
		\\    fsType = "auto";
		\\  };
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\  ];
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_flake,
				path: ".kai/machines/agent/flake.nix",
			}),
			WritesExactly({
				contents: expected_module,
				path: ".kai/machines/agent/machine.nix",
			}),
			ContainsStepsInOrder([
				PrintLine("machine: service web"),
				RunProgram({
					arguments: [
						"build",
						"--file",
						".kai/services/web/default.nix",
						"--out-link",
						".kai/artifacts/.services/web",
					],
					program: "nix",
				}),
				RunProgram({
					arguments: [
						"-RH",
						"--preserve=mode",
						"--",
						".kai/artifacts/.services/web",
						".kai/machines/agent/services/web",
					],
					program: "cp",
				}),
			]),
		]),
	)
}

# A secret-bearing machine imports sops-nix and stages its encrypted source.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\build app {
		\\  environment: server
		\\  run: ["touch", "app"]
		\\  output: "app"
		\\}
		\\
		\\secret api-key {
		\\  provider: sops
		\\  file: "secrets/api-key.json"
		\\}
		\\
		\\service web {
		\\  artifact: "app"
		\\  secrets: ["api-key"]
		\\  restart: on-failure
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: ["web", "openssh"]
		\\}
	expected_flake =
		\\{
		\\  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		\\  inputs.sops-nix = {
		\\    url = "github:Mic92/sops-nix";
		\\    inputs.nixpkgs.follows = "nixpkgs";
		\\  };
		\\  outputs = { nixpkgs, sops-nix, ... }:
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
		\\          ./machine.nix
		\\          sops-nix.nixosModules.sops
		\\          ./services/web
		\\        ];
		\\      };
		\\    in {
		\\      nixosConfigurations."agent" = machine;
		\\      kaiMachines."agent" = {
		\\        kind = "machine";
		\\        name = "agent";
		\\        inherit system;
		\\        closure = machine.config.system.build.toplevel;
		\\      };
		\\    };
		\\}
	expected_module =
		\\{ pkgs, ... }:
		\\{
		\\  boot.loader.grub.enable = false;
		\\  fileSystems."/" = {
		\\    device = "/dev/root";
		\\    fsType = "auto";
		\\  };
		\\  system.stateVersion = "25.05";
		\\  environment.systemPackages = [
		\\  ];
		\\  services."openssh".enable = true;
		\\  # Native OpenSSH is required, and this key must already exist.
		\\  # Its recipient must have encrypted every SOPS file.
		\\  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
		\\  sops.secrets."api-key" = {
		\\    format = "binary";
		\\    sopsFile = ./secrets/api-key.json;
		\\  };
		\\}
	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		Succeeds([
			WritesExactly({
				contents: expected_flake,
				path: ".kai/machines/agent/flake.nix",
			}),
			WritesExactly({
				contents: expected_module,
				path: ".kai/machines/agent/machine.nix",
			}),
			ContainsStagedFile({
				directory: ".kai/machines/agent/secrets",
				name: "api-key.json",
				source: "secrets/api-key.json",
			}),
		]),
	)
}

# Secret-bearing machines require OpenSSH and an existing recipient key.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\build app {
		\\  environment: server
		\\  run: ["touch", "app"]
		\\  output: "app"
		\\}
		\\
		\\secret api-key {
		\\  provider: sops
		\\  file: "secrets/api-key.json"
		\\}
		\\
		\\service web {
		\\  artifact: "app"
		\\  secrets: ["api-key"]
		\\  restart: on-failure
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-linux"
		\\  users: []
		\\  services: ["web"]
		\\}
	expected_error =
		\\machines with secrets require the native NixOS service
		\\'openssh' and an existing /etc/ssh/ssh_host_ed25519_key whose
		\\recipient encrypted the secret files

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "machine",
				location: None,
				message: expected_error,
				plugin: "std",
			}),
		),
	)
}

# Machine metadata records its closure, flake attribute, and target after first
# invalidating any metadata left by an older build.
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
	metadata_backend = "{\"backend\":\"nix\","
	metadata_closure =
		"\"closure_path\":\".kai/artifacts/machines/agent/closure\","
	metadata_flake_attribute =
		"\"flake_attribute\":\"kaiMachines.\\\"agent\\\".closure\","
	metadata_flake_path = "\"flake_path\":\".kai/machines/agent\","
	metadata_kind = "\"kind\":\"machine\","
	metadata_path =
		"\"metadata_path\":\".kai/artifacts/machines/agent/metadata.json\","
	metadata_name = "\"name\":\"agent\",\"schema\":1,"
	metadata_architecture = "\"target_architecture\":\"x86_64\","
	metadata_system = "\"target_system\":\"x86_64-linux\"}"
	expected_metadata = Str.join_with(
		[
			metadata_backend,
			metadata_closure,
			metadata_flake_attribute,
			metadata_flake_path,
			metadata_kind,
			metadata_path,
			metadata_name,
			metadata_architecture,
			metadata_system,
		],
		"",
	)

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		Succeeds([
			WritesAtPathExactly({
				contents: ["", expected_metadata],
				path: ".kai/artifacts/machines/agent/metadata.json",
			}),
		]),
	)
}

# An AArch64 machine exposes its closure artifact and builds the matching flake
# attribute into that artifact's path.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "aarch64-linux"
		\\  users: []
		\\  services: []
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: AARCH64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		Succeeds([
			ContainsArtifact({
				attributes: [
					{ key: "backend", value: "nix" },
					{ key: "target.architecture", value: "aarch64" },
					{ key: "target.system", value: "aarch64-linux" },
				],
				kind: "kai.machine.closure/v1",
				name: "agent",
				path: ".kai/artifacts/machines/agent/closure",
			}),
			ContainsStep(
				RunProgram({
					arguments: [
						"build",
						"path:.kai/machines/agent#kaiMachines.\"agent\".closure",
						"--no-update-lock-file",
						"--out-link",
						".kai/artifacts/machines/agent/closure",
					],
					program: "nix",
				}),
			),
		]),
	)
}

# Machine planning rejects hosts that cannot build NixOS machines.
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
	expected_error = "NixOS machine builds are supported only on Linux hosts"

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: MACOS },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "machine",
				location: None,
				message: expected_error,
				plugin: "std",
			}),
		),
	)
}

# Machine planning rejects a target that differs from the host architecture.
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
	expected_error =
		\\cross-architecture NixOS machine builds are not supported;
		\\target 'x86_64-linux' must match the host architecture

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: AARCH64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "machine",
				location: None,
				message: expected_error,
				plugin: "std",
			}),
		),
	)
}

# Machine planning rejects systems that NixOS machine builds do not support.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\machine agent {
		\\  environment: server
		\\  system: "x86_64-darwin"
		\\  users: []
		\\  services: []
		\\}
	error_start =
		"unsupported NixOS machine system 'x86_64-darwin'; "
	error_systems = "expected 'x86_64-linux' or 'aarch64-linux'"
	expected_error = "${error_start}${error_systems}"

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["machine", "agent"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "machine",
				location: None,
				message: expected_error,
				plugin: "std",
			}),
		),
	)
}
