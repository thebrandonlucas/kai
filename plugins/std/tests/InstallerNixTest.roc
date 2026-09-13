# Planning `kai installer <machine>` produces a guided installer artifact.
import std.StdPlugin
import util.PlanCheck

InstallerNixTest := [].{}

valid_kaifile =
	\\environment desktop {
	\\  packages: ["kai", "curl"]
	\\  overlays: ["github:thebrandonlucas/kai"]
	\\}
	\\
	\\machine desktop {
	\\  environment: desktop
	\\  system: "x86_64-linux"
	\\  users: ["blu"]
	\\  services: ["openssh"]
	\\  bootloader: "limine"
	\\  storage: "single-disk"
	\\}

input = |kaifile|
	{
		definitions: [StdPlugin.plugin],
		host: { arch: X64, os: LINUX },
		kaifile,
		workspace_root: ".kai",
	}

fails_with = |kaifile, message|
	PlanCheck.plan(
		input(kaifile),
		["installer", "desktop"],
		FailsWith(
			PlanningFailed({
				backend: "nix",
				command: "installer",
				location: None,
				message,
				plugin: "std",
			}),
		),
	)

# The installer reuses the installable machine module and emits both systems.
expect
	PlanCheck.plan(
		input(valid_kaifile),
		["installer", "desktop"],
		Succeeds([
			WritesContaining({
				contents: "boot.loader.limine.enable = true;",
				path: ".kai/installers/desktop/machine.nix",
			}),
			WritesContaining({
				contents: "device = \"/dev/disk/by-label/KAI_ROOT\";",
				path: ".kai/installers/desktop/machine.nix",
			}),
			WritesContaining({
				contents: "target = nixpkgs.lib.nixosSystem",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "installer = nixpkgs.lib.nixosSystem",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "installation-cd-minimal.nix",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "image.baseName = lib.mkForce \"desktop\";",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "isoImage.makeBiosBootable = false;",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "isoImage.volumeID = \"KAI_INSTALLER\";",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "services.getty.autologinUser = lib.mkForce \"root\";",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "pkgs.writeShellApplication",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "nixos-install-tools",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "environment.etc.\"kai-installer/Kaifile\".source",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "environment.etc.\"kai-installer/flake.lock\".source",
				path: ".kai/installers/desktop/flake.nix",
			}),
			WritesContaining({
				contents: "target.config.system.build.toplevel",
				path: ".kai/installers/desktop/flake.nix",
			}),
		]),
	)

# The expanded Kaifile is embedded beside the generated installer lock.
expect
	PlanCheck.plan(
		input(valid_kaifile),
		["installer", "desktop"],
		Succeeds([
			WritesExactly({
				contents: valid_kaifile,
				path: ".kai/installers/desktop/Kaifile",
			}),
			ContainsStepsInOrder([
				RunProgram({
					arguments: [
						"flake",
						"lock",
						"path:.kai/installers/desktop",
						"--reference-lock-file",
						"Kaifile.lock",
						"--output-lock-file",
						".kai/installers/desktop/flake.lock",
					],
					program: "nix",
				}),
				RunProgram({
					arguments: [
						"build",
						"path:.kai/installers/desktop#kaiInstallers.\"desktop\"",
						"--no-update-lock-file",
						"--out-link",
						".kai/artifacts/installers/desktop/result",
					],
					program: "nix",
				}),
			]),
		]),
	)

# Artifact metadata is invalidated, finalized, and describes the ISO output.
expect {
	expected_metadata = Str.join_with(
		[
			"{\"backend\":\"nix\",",
			"\"flake_attribute\":\"kaiInstallers.\\\"desktop\\\"\",",
			"\"flake_path\":\".kai/installers/desktop\",",
			"\"format\":\"iso\",\"kind\":\"machine-installer\",",
			"\"metadata_path\":",
			"\".kai/artifacts/installers/desktop/metadata.json\",",
			"\"name\":\"desktop\",",
			"\"output_path\":",
			"\".kai/artifacts/installers/desktop/result/iso/desktop.iso\",",
			"\"schema\":1,\"target_architecture\":\"x86_64\",",
			"\"target_system\":\"x86_64-linux\"}",
		],
		"",
	)
	PlanCheck.plan(
		input(valid_kaifile),
		["installer", "desktop"],
		Succeeds([
			ContainsArtifact({
				attributes: [
					{ key: "backend", value: "nix" },
					{ key: "format", value: "iso" },
					{ key: "target.architecture", value: "x86_64" },
					{ key: "target.system", value: "x86_64-linux" },
				],
				kind: "kai.machine.installer/v1",
				name: "desktop",
				path: Str.join_with(
					[
						".kai/artifacts/installers/desktop/result/iso/",
						"desktop.iso",
					],
					"",
				),
			}),
			WritesAtPathExactly({
				contents: ["", expected_metadata],
				path: ".kai/artifacts/installers/desktop/metadata.json",
			}),
		]),
	)
}

# The generated program confirms and revalidates one selected disk safely.
expect
	PlanCheck.plan(
		input(valid_kaifile),
		["installer", "desktop"],
		Succeeds([
			WritesContaining({
				contents: "set -euo pipefail",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "KAI_INSTALLER_READY",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "--output NAME,TYPE,RM,RO,SIZE",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "[ -d /sys/firmware/efi/efivars ]",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "live_source=$(findfs LABEL=KAI_INSTALLER",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "Selected disk has active holders",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "Selected disk is smaller than 16 GiB",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "Selected disk identity changed",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "trap cleanup EXIT",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "Type $disk to confirm:",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "validate_disk \"$disk\"",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "--change-name=1:KAI_BOOT \"$disk\"",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "--output NAME,TYPE,PARTN -- \"$disk\"",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "nixos-install --root /mnt --system \"$target_closure\"",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "nixos-enter --root /mnt -c 'passwd blu'",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesContaining({
				contents: "\"$src/flake.lock\" \"$dst/Kaifile.lock\"",
				path: ".kai/installers/desktop/installer.sh",
			}),
			WritesNotContaining({
				contents: "/dev/disk/by-",
				path: ".kai/installers/desktop/installer.sh",
			}),
		]),
	)

# Generated services remain prerequisites and are copied into both systems.
expect {
	kaifile =
		\\environment desktop {
		\\  packages: ["kai"]
		\\}
		\\
		\\build app {
		\\  environment: desktop
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
		\\machine desktop {
		\\  environment: desktop
		\\  system: "x86_64-linux"
		\\  users: ["blu"]
		\\  services: ["web"]
		\\  bootloader: "limine"
		\\  storage: "single-disk"
		\\}
	PlanCheck.plan(
		input(kaifile),
		["installer", "desktop"],
		Succeeds([
			ContainsStep(PrintLine("installer: service web")),
			ContainsStep(
				RunProgram({
					arguments: [
						"-RH",
						"--preserve=mode",
						"--",
						".kai/artifacts/.services/web",
						".kai/installers/desktop/services/web",
					],
					program: "cp",
				}),
			),
			WritesContaining({
				contents: "./services/web",
				path: ".kai/installers/desktop/flake.nix",
			}),
		]),
	)
}

# Installer-specific restrictions fail during pure planning.
expect {
	no_profile =
		\\environment desktop {
		\\  packages: ["kai"]
		\\}
		\\machine desktop {
		\\  environment: desktop
		\\  system: "x86_64-linux"
		\\  users: ["blu"]
		\\}
	two_users =
		\\environment desktop {
		\\  packages: ["kai"]
		\\}
		\\machine desktop {
		\\  environment: desktop
		\\  system: "x86_64-linux"
		\\  users: ["blu", "kai"]
		\\  bootloader: "limine"
		\\  storage: "single-disk"
		\\}
	missing_kai =
		\\environment desktop {
		\\  packages: ["curl"]
		\\}
		\\machine desktop {
		\\  environment: desktop
		\\  system: "x86_64-linux"
		\\  users: ["blu"]
		\\  bootloader: "limine"
		\\  storage: "single-disk"
		\\}
	aarch64 =
		\\environment desktop {
		\\  packages: ["kai"]
		\\}
		\\machine desktop {
		\\  environment: desktop
		\\  system: "aarch64-linux"
		\\  users: ["blu"]
		\\  bootloader: "limine"
		\\  storage: "single-disk"
		\\}
	fails_with(
		no_profile,
		"installer requires bootloader 'limine' and storage 'single-disk'",
	) and
		fails_with(
			two_users,
			"installer requires exactly one declared machine user",
		) and
			fails_with(
				missing_kai,
				"installer machine environment must include package 'kai'",
			) and
				fails_with(
					aarch64,
					"installer supports only 'x86_64-linux'; got 'aarch64-linux'",
				)
}
