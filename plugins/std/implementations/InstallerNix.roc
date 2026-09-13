# Builds guided full-disk machine installer ISOs with Nix.
import parser.Fields
import kai.Plugin
import backends.Nix as NixBackend
import commands.Installer as InstallerCommand
import MachineNix

InstallerNix := [].{
	InstallerServices : List(Plugin.Artifact)
	InstallerSteps : List(Plugin.ExecutionStep)

	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		backend: NixBackend.backend.name,
		command: InstallerCommand.command_syntax.name,
		plan: InstallerNix.plan,
		validator: NoValidation,
	}

	installer_output_path : Str, Str -> Str
	installer_output_path = |root, name|
		Plugin.workspace_path(root, "artifacts/installers/${name}/result")

	installer_file_path : Str, Str -> Str
	installer_file_path = |root, name|
		"${InstallerNix.installer_output_path(root, name)}/iso/${name}.iso"

	installer_flake_path : Str, Str -> Str
	installer_flake_path = |root, name|
		Plugin.workspace_path(root, "installers/${name}")

	installer_metadata_path : Str, Str -> Str
	installer_metadata_path = |root, name|
		Plugin.workspace_path(
			root,
			"artifacts/installers/${name}/metadata.json",
		)

	installer_steps :
		Str, Str, Str, Str, Str, Str, Str, Str, InstallerServices -> InstallerSteps
	installer_steps = |
		root,
		kaifile_path,
		name,
		flake,
		module_text,
		script,
		kaifile,
		metadata,
		services,
	| {
		flake_path = InstallerNix.installer_flake_path(root, name)
		metadata_path = InstallerNix.installer_metadata_path(root, name)
		[
			# Invalidate an older artifact before any fallible step.
			WriteFile({ contents: "", path: metadata_path }),
			WriteFile({ contents: flake, path: "${flake_path}/flake.nix" }),
			WriteFile({ contents: module_text, path: "${flake_path}/machine.nix" }),
			WriteFile({ contents: script, path: "${flake_path}/installer.sh" }),
			WriteFile({ contents: kaifile, path: "${flake_path}/Kaifile" }),
		]
			.concat(MachineNix.service_copy_steps(flake_path, services))
			.concat(NixBackend.lock_steps(flake_path, kaifile_path))
			.concat([
				WriteFile({
					contents: "",
					path: Plugin.workspace_path(
						root,
						"artifacts/installers/${name}/.keep",
					),
				}),
				NixBackend.run([
					"build",
					"path:${flake_path}#kaiInstallers.\"${name}\"",
					"--no-update-lock-file",
					"--out-link",
					InstallerNix.installer_output_path(root, name),
				]),
				WriteFile({ contents: metadata, path: metadata_path }),
			])
	}

	plan :
		Plugin.CommandPlanningInput ->
			Try(
				Plugin.BackendCommandPlan,
				Plugin.BackendPlanningDiagnostic,
			)
	plan = |input| {
		system = Fields.get_string(input.command_fields, "system") ? |_|
			{
				byte_offset: None,
				message: "validated machine block is missing 'system'",
			}
		if system != "x86_64-linux" {
			return Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"installer supports only 'x86_64-linux'; got '",
						system,
						"'",
					],
					"",
				),
			})
		}
		declared_users = MachineNix.optional_strings(input.command_fields, "users")?
		if declared_users.len() != 1 {
			return Err({
				byte_offset: None,
				message: "installer requires exactly one declared machine user",
			})
		}
		spec = MachineNix.machine_spec(input, "installer")?
		match spec.installation_profile {
			NoInstallationProfile => return Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"installer requires bootloader 'limine' and storage ",
						"'single-disk'",
					],
					"",
				),
			})
			LimineSingleDisk => {}
		}
		if !spec.pkgs.contains("kai") {
			return Err({
				byte_offset: None,
				message: "installer machine environment must include package 'kai'",
			})
		}
		prerequisite_commands = MachineNix.service_prerequisite_commands(
			spec.generated_services,
			"installer",
		)
		services = match input.prerequisite_artifacts {
			NotResolved =>
				if prerequisite_commands.is_empty() {
					Ok([])
				} else {
					return Ok({
						artifacts: [],
						prerequisite_commands,
						requested_packages: spec.pkgs,
						steps: [],
					})
				}
			Resolved(artifacts) =>
				MachineNix.resolve_services(
					artifacts,
					spec.generated_services,
					spec.target_system,
				)
			}?
		native_services = spec.services.keep_if(|service|
			!spec.generated_services.contains(service))
		schema : U64
		schema = 1
		metadata = Json.to_str({
			backend: NixBackend.backend.name,
			flake_attribute: "kaiInstallers.\"${spec.name}\"",
			flake_path: InstallerNix.installer_flake_path(
				input.workspace_root,
				spec.name,
			),
			format: "iso",
			kind: "machine-installer",
			metadata_path: InstallerNix.installer_metadata_path(
				input.workspace_root,
				spec.name,
			),
			name: spec.name,
			output_path: InstallerNix.installer_file_path(
				input.workspace_root,
				spec.name,
			),
			schema,
			target_architecture: spec.target_architecture,
			target_system: spec.target_system,
		})
		Ok(
			Plugin.BackendCommandPlan.{
				artifacts: [
					{
						attributes: [
							{ key: "backend", value: NixBackend.backend.name },
							{ key: "format", value: "iso" },
							{
								key: "target.architecture",
								value: spec.target_architecture,
							},
							{ key: "target.system", value: spec.target_system },
						],
						kind: "kai.machine.installer/v1",
						name: spec.name,
						path: InstallerNix.installer_file_path(
							input.workspace_root,
							spec.name,
						),
					},
				],
				prerequisite_commands,
				requested_packages: spec.pkgs,
				steps: InstallerNix.installer_steps(
					input.workspace_root,
					input.kaifile_path,
					spec.name,
					InstallerNix.render_flake(
						spec.name,
						spec.target_system,
						spec.locked_overlays,
						spec.overlays,
						services,
					),
					MachineNix.render_module(
						spec.pkgs,
						spec.users,
						native_services,
						spec.installation_profile,
					),
					InstallerNix.render_script(spec.users.first() ?? ""),
					input.kaifile_text,
					metadata,
					services,
				),
			},
		)
	}

	render_flake : Str, Str, List(Str), List(Str), List(Plugin.Artifact) -> Str
	render_flake = |name, system, locked_overlays, overlays, services| {
		overlay_lines = overlays.map(
			|overlay|
				"          ${
					NixBackend.overlay_expression(
						locked_overlays,
						overlay,
						0,
					)
				}",
		)
		outputs_args = NixBackend.overlay_outputs_args(locked_overlays)
		target_path = NixBackend.nix_interpolation(
			"target.config.system.build.toplevel",
		)
		program_path = Str.join_with(
			[
				NixBackend.nix_interpolation("installerProgram"),
				"/bin/kai-installer",
			],
			"",
		)
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		].concat(NixBackend.input_lines(locked_overlays)).concat([
			"  outputs = { ${outputs_args}, ... }:",
			"    let",
			"      system = \"${system}\";",
			"      pkgs = import nixpkgs {",
			"        inherit system;",
			"        overlays = [",
		]).concat(overlay_lines).concat([
			"        ];",
			"      };",
			"      target = nixpkgs.lib.nixosSystem {",
			"        inherit system;",
			"        modules = [",
			"          { nixpkgs.pkgs = pkgs; }",
			"          ./machine.nix",
		]).concat(MachineNix.service_module_lines(services)).concat([
			"        ];",
			"      };",
			"      installerProgram = pkgs.writeShellApplication {",
			"        name = \"kai-installer\";",
			"        runtimeInputs = with pkgs; [",
			"          coreutils",
			"          dosfstools",
			"          e2fsprogs",
			"          findutils",
			"          gawk",
			"          gnugrep",
			"          gptfdisk",
			"          gum",
			"          nixos-install-tools",
			"          systemd",
			"          util-linux",
			"        ];",
			"        text = builtins.replaceStrings",
			"          [ \"@kai-target-closure@\" ]",
			"          [ \"${target_path}\" ]",
			"          (builtins.readFile ./installer.sh);",
			"      };",
			"      installer = nixpkgs.lib.nixosSystem {",
			"        inherit system;",
			"        modules = [",
			"          { nixpkgs.pkgs = pkgs; }",
			"          ({ lib, modulesPath, ... }: {",
			"            imports = [",
			"              (modulesPath + \"/installer/cd-dvd/\"",
			"                + \"installation-cd-minimal.nix\")",
			"            ];",
			"            image.baseName = lib.mkForce \"${name}\";",
			"            isoImage.makeBiosBootable = false;",
			"            isoImage.makeEfiBootable = true;",
			"            isoImage.volumeID = \"KAI_INSTALLER\";",
			"            services.getty.autologinUser = lib.mkForce \"root\";",
			"            environment.systemPackages = [ installerProgram ];",
			"            environment.loginShellInit = ''",
			"              if [ \"$(tty)\" = /dev/tty1 ]; then",
			"                ${program_path}",
			"              fi",
			"            '';",
			"            environment.etc.\"kai-installer/Kaifile\".source =",
			"              ./Kaifile;",
			"            environment.etc.\"kai-installer/flake.lock\".source =",
			"              ./flake.lock;",
			"            isoImage.storeContents = [",
			"              target.config.system.build.toplevel",
			"            ];",
			"          })",
			"        ];",
			"      };",
			"    in {",
			"      nixosConfigurations.\"${name}\" = target;",
			"      kaiInstallers.\"${name}\" =",
			"        installer.config.system.build.isoImage;",
			"    };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	render_script : Str -> Str
	render_script = |user|
		Str.join_with(
			[
				\\#!/usr/bin/env bash
				\\set -euo pipefail
				\\
				\\target_closure=@kai-target-closure@
				\\installer_user='${user}'
				\\minimum_disk_bytes=17179869184
				\\live_disk=
				\\
				\\fail() {
				\\  printf 'Error: %s\\n' "$*" >&2
				\\  exit 1
				\\}
				\\
				\\cleanup() {
				\\  set +e
				\\  mountpoint --quiet /mnt && umount --recursive -- /mnt
				\\}
				\\
				\\trap cleanup EXIT
				\\trap 'printf "Installation failed; no reboot was attempted.\\n" >&2' ERR
				\\
				\\lsblk_rows() {
				\\  lsblk --noheadings --raw --paths "$@"
				\\}
				\\
				\\parent_disk() {
				\\  source=$1
				\\  [ -n "$source" ] || return 0
				\\  lsblk_rows --inverse --output NAME,TYPE -- "$source" |
				\\    awk '$2 == "disk" { print $1; exit }'
				\\}
				\\
				\\has_holders() {
				\\  while read -r node; do
				\\    holders=/sys/class/block/$(basename "$node")/holders
				\\    [ -d "$holders" ] || continue
				\\    if find "$holders" -mindepth 1 -maxdepth 1 -print -quit |
				\\      grep --quiet .; then
				\\      return 0
				\\    fi
				\\  done < <(lsblk_rows --output NAME -- "$1")
				\\  return 1
				\\}
				\\
				\\list_disks() {
				\\  while read -r path type removable readonly size; do
				\\    [ "$type" = disk ] || continue
				\\    [ "$removable" = 0 ] || continue
				\\    [ "$readonly" = 0 ] || continue
				\\    [ "$size" -ge "$minimum_disk_bytes" ] || continue
				\\    [ "$path" != "$live_disk" ] || continue
				\\    has_holders "$path" && continue
				\\    mounts=$(lsblk_rows --output MOUNTPOINTS -- "$path") || continue
				\\    if [[ ! "$mounts" =~ [^[:space:]] ]]; then
				\\      printf '%s\\n' "$path"
				\\    fi
				\\  done < <(lsblk_rows --bytes --nodeps --output NAME,TYPE,RM,RO,SIZE)
				\\}
				\\
				\\validate_disk() {
				\\  candidate=$1
				\\  [ -b "$candidate" ] ||
				\\    fail "Selected path is not a block device: $candidate"
				\\  fields=$(lsblk_rows --nodeps --output TYPE,RM,RO -- "$candidate") ||
				\\    fail "Cannot inspect selected disk: $candidate"
				\\  read -r type removable readonly <<< "$fields"
				\\  [ "$type" = disk ] ||
				\\    fail "Selected device is not a whole disk: $candidate"
				\\  [ "$removable" = 0 ] ||
				\\    fail "Selected disk is removable: $candidate"
				\\  [ "$readonly" = 0 ] ||
				\\    fail "Selected disk is read-only: $candidate"
				\\  [ "$candidate" != "$live_disk" ] ||
				\\    fail "Selected disk contains the running installer: $candidate"
				\\  size=$(lsblk_rows --bytes --nodeps --output SIZE -- "$candidate") ||
				\\    fail "Cannot read selected disk capacity: $candidate"
				\\  [ "$size" -ge "$minimum_disk_bytes" ] ||
				\\    fail "Selected disk is smaller than 16 GiB: $candidate"
				\\  ! has_holders "$candidate" ||
				\\    fail "Selected disk has active holders: $candidate"
				\\  mounts=$(lsblk_rows --output MOUNTPOINTS -- "$candidate") ||
				\\    fail "Cannot inspect mounts on: $candidate"
				\\  [[ ! "$mounts" =~ [^[:space:]] ]] ||
				\\    fail "Selected disk has mounted descendants: $candidate"
				\\}
				\\
				\\disk_identity() {
				\\  lsblk_rows --bytes --nodeps --output MAJ:MIN,SIZE,SERIAL,WWN -- "$1"
				\\}
				\\
				\\reject_label_conflicts() {
				\\  for label in KAI_BOOT KAI_ROOT; do
				\\    while read -r existing; do
				\\      [ -n "$existing" ] || continue
				\\      owner=$(parent_disk "$existing")
				\\      [ "$owner" = "$disk" ] ||
				\\        fail "Filesystem label $label already exists on $owner"
				\\    done < <(blkid --match-token "LABEL=$label" --output device)
				\\  done
				\\}
				\\
				\\partition_for() {
				\\  number=$1
				\\  partitions=$(
				\\    lsblk_rows --output NAME,TYPE,PARTN -- "$disk" |
				\\      awk -v part="$number" '$2 == "part" && $3 == part { print $1 }'
				\\  )
				\\  count=$(
				\\    printf '%s\\n' "$partitions" |
				\\      awk 'NF { count++ } END { print count + 0 }'
				\\  )
				\\  [ "$count" = 1 ] ||
				\\    fail "Expected one partition $number below $disk; found $count"
				\\  printf '%s\\n' "$partitions"
				\\}
				\\
				\\[ "$(id -u)" = 0 ] || fail "The installer must run as root."
				\\[ -d /sys/firmware/efi/efivars ] ||
				\\  fail "Boot this installer in UEFI mode."
				\\[ -r /etc/kai-installer/Kaifile ] ||
				\\  fail "The installer Kaifile payload is missing."
				\\[ -r /etc/kai-installer/flake.lock ] ||
				\\  fail "The installer lock payload is missing."
				\\live_source=$(findfs LABEL=KAI_INSTALLER 2>/dev/null || true)
				\\live_disk=$(parent_disk "$live_source")
				\\disks=$(list_disks)
				\\[ -n "$disks" ] ||
				\\  fail "No unmounted, non-removable whole disks are available."
				\\printf 'Available installation disks (path | model | size):\\n'
				\\while read -r candidate; do
				\\  model=$(lsblk_rows --nodeps --output MODEL -- "$candidate" |
				\\    awk '{$1=$1; print}')
				\\  size=$(lsblk_rows --nodeps --output SIZE -- "$candidate" |
				\\    awk '{$1=$1; print}')
				\\  [ -n "$model" ] || model=unknown
				\\  printf '  %s | %s | %s\\n' "$candidate" "$model" "$size"
				\\done <<< "$disks"
				\\printf 'KAI_INSTALLER_READY\\n' > /dev/ttyS0 2>/dev/null || true
				\\disk=$(printf '%s\\n' "$disks" |
				\\  gum choose --header 'Select the disk to erase') ||
				\\  fail "No disk selected."
				\\[ -n "$disk" ] || fail "No disk selected."
				\\validate_disk "$disk"
				\\reject_label_conflicts
				\\identity=$(disk_identity "$disk")
				\\printf '\\nKai will erase %s and create KAI_BOOT and KAI_ROOT.\\n' "$disk"
				\\typed=$(gum input --prompt "Type $disk to confirm: ") ||
				\\  fail "Confirmation cancelled."
				\\[ "$typed" = "$disk" ] ||
				\\  fail "Confirmation did not exactly match $disk."
				\\validate_disk "$disk"
				\\[ "$(disk_identity "$disk")" = "$identity" ] ||
				\\  fail "Selected disk identity changed during confirmation."
				\\reject_label_conflicts
				\\
				\\sgdisk --zap-all "$disk"
				\\sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:KAI_BOOT "$disk"
				\\sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:KAI_ROOT "$disk"
				\\udevadm settle
				\\boot_partition=$(partition_for 1)
				\\root_partition=$(partition_for 2)
				\\[ -b "$boot_partition" ] ||
				\\  fail "Boot partition did not appear: $boot_partition"
				\\[ -b "$root_partition" ] ||
				\\  fail "Root partition did not appear: $root_partition"
				\\mkfs.vfat -F 32 -n KAI_BOOT -- "$boot_partition"
				\\mkfs.ext4 -F -L KAI_ROOT -- "$root_partition"
				\\mount -- "$root_partition" /mnt
				\\mkdir -p -- /mnt/boot
				\\mount -- "$boot_partition" /mnt/boot
				\\nixos-install --root /mnt --system "$target_closure" --no-root-passwd
				\\src=/etc/kai-installer
				\\dst=/mnt/etc/kai
				\\install -D -m 0644 -- "$src/Kaifile" "$dst/Kaifile"
				\\install -D -m 0644 -- "$src/flake.lock" "$dst/Kaifile.lock"
				\\printf '\\nSet the password for %s.\\n' "$installer_user"
				\\nixos-enter --root /mnt -c 'passwd ${user}'
				\\sync
				\\umount --recursive -- /mnt
				\\printf '\\nInstallation complete.\\n'
				\\if gum confirm 'Reboot now?'; then
				\\  reboot
				\\fi
				,
			],
			"\n",
		)
}
