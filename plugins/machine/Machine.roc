# The machine plugin: `Machine(name, [...])` settings beside std's, each a
# system from a small typed core, and the `kai machine` and `kai secret`
# commands, which NixosBackend implements on the nix backend from
# MachineModel.
import pf.Command
import pf.Plugin
import std.Config
import std.EnvName
import std.StdModel exposing [Model]
import std.System
import MachineModel
import NixosBackend

Machine := [].{

	## A machine. On the nix backend it is a NixOS system, rendered as
	## `nixosConfigurations.<name>` in std's generated flake from its
	## "default" package source.
	Setting : [Machine(Str, List(MachineSetting))]

	## System and StateVersion are required, and every setting but User
	## occurs at most once. HostName defaults to the machine's name. Host is
	## the SSH target, `user@host` or `host`, that switch, rollback and
	## generations act on instead of the host kai runs on. Ssh runs
	## OpenSSH with key logins only, root's only when root has keys. Firewall
	## opens ports beside OpenSSH's. Use puts a std environment's tools on
	## the system's PATH. Disk is the disk layout `kai machine install`
	## partitions, which the system mounts and boots from. Operators are the
	## age recipients or SSH public keys of whoever may decrypt the machine's
	## host key and Secrets, which `kai secret set` writes and the system
	## decrypts into /run/secrets. Modules are NixOS module files relative to
	## the project, which receive the flake's `inputs`.
	MachineSetting : [
		System(System),
		HostName(Str),
		Host(Str),
		User(Str, List(UserSetting)),
		Ssh,
		Firewall(List(FirewallSetting)),
		Use(EnvName),
		TimeZone(Str),
		StateVersion(Str),
		Disk(DiskSetting),
		Operators(List(Str)),
		Secrets(List(SecretSetting)),
		Modules(List(Str)),
	]

	## A secret, by name: a letter, then letters, digits, `-`, `_` or `.`.
	## It is the file /run/secrets/NAME, owned by Owner (default root) and
	## Group (default root), with octal Mode (default "0400").
	SecretSetting : [Secret(Str, List(SecretOption))]

	SecretOption : [Owner(Str), Group(Str), Mode(Str)]

	## The one disk layout: the whole disk at an absolute `/dev/...` path,
	## such as "/dev/sda", holding a BIOS boot partition, an EFI system
	## partition at /boot and an ext4 root, so it boots on BIOS and UEFI.
	DiskSetting : [SingleDisk(Str)]

	## A user's authorized SSH public keys and supplementary groups. Every
	## user but root is an ordinary user.
	UserSetting : [SshKeys(List(Str)), Groups(List(Str))]

	## Ports the firewall opens.
	FirewallSetting : [Tcp(List(U16)), Udp(List(U16))]

	Machines : List(MachineModel.Machine)

	## `project` is std's settings, whose environments and inputs machines
	## use; a machine's System must be one of its Systems.
	plugin : List(Config.Setting), List(Setting) -> Plugin
	plugin = |project, settings|
		match Machine.checked(project, settings) {
			Ok(machines) =>
				Plugin.new({
					name: "machine",
					version: "",
					describe: "",
					commands: [Machine.command(machines), Machine.secret_command(machines)],
					backends: [],
					implementations: [
						NixosBackend.implementation(project, machines),
						NixosBackend.secret_implementation(project, machines),
					],
				})
			Err(problems) => Plugin.invalid("machine", problems)
		}

	command : Machines -> Command
	command = |machines|
		Command.{
			name: "machine",
			summary: Machine.page.description,
			help: Machine.page,
			args: [
				Name({
					name: "action",
					help: "What to do with the machine.",
					choices: [
						("build", "Build the machine's system and print its store path."),
						("switch", "Build the machine's system and switch its host to it."),
						("rollback", "Switch the machine's host back to its previous system."),
						("generations", "List the system generations of the machine's host."),
						("install", "Erase the --to server's Disk and install the machine."),
					].map(|(value, summary)| { value, summary, details: [] }),
					default: Required,
				}),
				Value({
					name: "to",
					short: "",
					help: "Act on this SSH target, user@host, not the machine's Host; "
						.concat("install needs it, since it erases the target's disk."),
				}),
				Machine.identity,
				Trailing({
					name: "machine",
					help: "The machine.",
					choices: machines.map(
						|m| { value: m.name, summary: "NixOS on ${m.system}", details: [] },
					),
				}),
			],
			lock: ReadsLock,
		}

	page : Command.Page
	page = {
		description: "Build, install or switch to a NixOS machine the project has.",
		examples: [
			"kai machine build web",
			"kai machine install web --to root@203.0.113.7",
			"kai --dry-run machine switch web",
			"kai machine switch web --to admin@203.0.113.7",
			"kai machine rollback web",
			"kai machine generations web",
		],
		config: [
			"Machine(\"web\", [System(\"x86_64-linux\"), StateVersion(\"25.05\"),",
			"  Host(\"admin@web.example.com\"),",
			"  User(\"admin\", [SshKeys([\"ssh-ed25519 AAAA...\"])]), Ssh,",
			"  Disk(SingleDisk(\"/dev/sda\")),",
			"  Operators([\"age1...\"]),",
			"  Secrets([Secret(\"app-key\", [Owner(\"app\")])]),",
			"  Modules([\"nixos/web.nix\"])]),",
		],
	}

	## The age or SSH identity that decrypts a machine's host key and
	## secrets.
	identity : Command.Arg
	identity = Path({
		name: "identity",
		short: "i",
		help: "Decrypt with this age or SSH private key (default ~/.ssh/id_ed25519).",
	})

	## `kai secret`, which encrypts a machine's secrets to its Operators and
	## host key.
	secret_command : Machines -> Command
	secret_command = |machines|
		Command.{
			name: "secret",
			summary: Machine.secret_page.description,
			help: Machine.secret_page,
			args: [
				Name({
					name: "action",
					help: "What to do with the machine's secrets.",
					choices: [
						("set", "Encrypt the value on stdin as a machine's secret."),
						("rekey", "Encrypt a machine's secrets again to its current keys."),
					].map(|(value, summary)| { value, summary, details: [] }),
					default: Required,
				}),
				Machine.identity,
				Trailing({
					name: "names",
					help: "The machine, then for set the secret: ".concat(
						Str.join_with(machines.map(|m| m.name), ", "),
					),
					choices: [],
				}),
			],
			lock: ReadsLock,
		}

	secret_page : Command.Page
	secret_page = {
		description: "Encrypt a machine's secrets to its Operators and host key.",
		examples: [
			"printf %s \"$API_KEY\" | kai secret set web app-key",
			"kai secret rekey web",
			"kai secret rekey web --identity ~/.ssh/id_ed25519",
		],
		config: [
			"Input(\"agenix\", \"github:ryantm/agenix\"),   # in std's settings",
			"Machine(\"web\", [..., Operators([\"age1...\", \"ssh-ed25519 AAAA...\"]),",
			"  Secrets([Secret(\"app-key\", [Owner(\"app\"), Mode(\"0400\")])])]),",
		],
	}

	## The machines, or every problem with the settings.
	checked : List(Config.Setting), List(Setting) -> Try(Machines, List(Str))
	checked = |project, settings| {
		model = StdModel.from_settings(project).map_err(|why| [why])?
		var $machines = []
		var $problems = []
		for setting in settings {
			(name, parts) = match setting {
				Machine(machine_name, machine_settings) => (machine_name, machine_settings)
			}
			m = Machine.machine(name, parts)
			given = parts
				.map(Machine.setting_name)
				.drop_if(|s| s == "User")
			# An empty Host or Operators folds to none, so it is found here.
			empty_host = parts.any(
				|part|
					match part {
						Host(target) => target.is_empty()
						_ => Bool.False
					},
			)
			empty_operators = parts.any(
				|part|
					match part {
						Operators(keys) => keys.is_empty()
						_ => Bool.False
					},
			)
			empty_host_problem = "Host is empty; ${MachineModel.target_form}"
			empty = if (empty_host) [empty_host_problem] else []
			no_operator = "Operators needs at least one key"
			# Each Secret's options, folded, hide the ones given twice.
			secret_options = parts.join_map(
				|part|
					match part {
						Secrets(secrets) => secrets
						_ => []
					},
			)
			repeated_options = secret_options.join_map(
				|Secret(secret, options)|
					Machine.repeated(options.map(Machine.option_name))
						.map(|o| "secret ${secret}: ${o} is given more than once"),
			)
			found = Machine.repeated(given)
				.map(|s| "${s} is given more than once")
				.concat(empty)
				.concat(if (empty_operators) [no_operator] else [])
				.concat(repeated_options)
				.concat(Machine.problems(model, m))
				.concat(NixosBackend.problems(project, m))
			$problems = $problems.concat(found.map(|p| "machine ${name}: ${p}"))
			$machines = $machines.append(m)
		}
		duplicated = Machine.repeated($machines.map(|m| m.name))
			.map(|name| "machine ${name} is declared more than once")
		problems = $problems.concat(duplicated)
		if (problems.is_empty()) Ok($machines) else Err(problems)
	}

	## The names that occur more than once in `names`, each once.
	repeated : List(Str) -> List(Str)
	repeated = |names|
		names.fold(
			[],
			|found, name|
				if names.keep_if(|n| n == name).len() > 1 and !found.contains(name) {
					found.append(name)
				} else {
					found
				},
		)

	setting_name : MachineSetting -> Str
	setting_name = |setting|
		match setting {
			System(_) => "System"
			HostName(_) => "HostName"
			Host(_) => "Host"
			User(_, _) => "User"
			Ssh => "Ssh"
			Firewall(_) => "Firewall"
			Use(_) => "Use"
			TimeZone(_) => "TimeZone"
			StateVersion(_) => "StateVersion"
			Disk(_) => "Disk"
			Operators(_) => "Operators"
			Secrets(_) => "Secrets"
			Modules(_) => "Modules"
		}

	option_name : SecretOption -> Str
	option_name = |option|
		match option {
			Owner(_) => "Owner"
			Group(_) => "Group"
			Mode(_) => "Mode"
		}

	## A machine's settings folded into its fields; a later one wins, and
	## `checked` reports it.
	machine : Str, List(MachineSetting) -> MachineModel.Machine
	machine = |name, parts|
		parts.fold(
			{
				name,
				system: "",
				host_name: name,
				host: "",
				users: [],
				ssh: Bool.False,
				tcp_ports: [],
				udp_ports: [],
				environment: "",
				time_zone: "",
				state_version: "",
				disk: NoDisk,
				operators: [],
				secrets: [],
				modules: [],
			},
			|m, part|
				match part {
					System(system) => { ..m, system: system.to_str() }
					HostName(host_name) => { ..m, host_name }
					Host(host) => { ..m, host }
					User(user, user_settings) => {
						..m,
						users: m.users.append(Machine.user(user, user_settings)),
					}
					Ssh => { ..m, ssh: Bool.True }
					Firewall(ports) => {
						..m,
						tcp_ports: ports.join_map(
							|p|
								match p {
									Tcp(list) => list
									Udp(_) => []
								},
						),
						udp_ports: ports.join_map(
							|p|
								match p {
									Udp(list) => list
									Tcp(_) => []
								},
						),
					}
					Use(environment) => { ..m, environment: environment.to_str() }
					TimeZone(time_zone) => { ..m, time_zone }
					StateVersion(state_version) => { ..m, state_version }
					Disk(SingleDisk(device)) => { ..m, disk: SingleDisk(device) }
					Operators(operators) => { ..m, operators }
					Secrets(secrets) => { ..m, secrets: secrets.map(Machine.secret) }
					Modules(modules) => { ..m, modules }
				},
		)

	secret : SecretSetting -> MachineModel.Secret
	secret = |Secret(name, options)|
		options.fold(
			{ name, owner: "root", group: "root", mode: "0400" },
			|s, option|
				match option {
					Owner(owner) => { ..s, owner }
					Group(group) => { ..s, group }
					Mode(mode) => { ..s, mode }
				},
		)

	user : Str, List(UserSetting) -> MachineModel.User
	user = |name, settings|
		settings.fold(
			{ name, keys: [], groups: [] },
			|u, setting|
				match setting {
					SshKeys(keys) => { ..u, keys: u.keys.concat(keys) }
					Groups(groups) => { ..u, groups: u.groups.concat(groups) }
				},
		)

	## What is wrong with machine `m` on any backend, checked as Kaifile.roc
	## compiles.
	problems : Model, MachineModel.Machine -> List(Str)
	problems = |model, m| {
		var $found = []
		if !Machine.valid_machine_name(m.name) {
			$found = $found.append(
				"a machine name is a letter, then letters, digits, - or _",
			)
		}
		linux = ["x86_64-linux", "aarch64-linux"]
		if m.system.is_empty() {
			$found = $found.append("System is required")
		} else if !linux.contains(m.system) {
			$found = $found.append(
				"System ${m.system} is not x86_64-linux or aarch64-linux",
			)
		} else if !model.systems.contains(m.system) {
			$found = $found.append(
				"System ${m.system} is not among the project's Systems",
			)
		}
		if !Machine.valid_state_version(m.state_version) {
			$found = $found.append(
				"StateVersion is required, as a release such as \"25.05\"",
			)
		}
		if !Machine.valid_host_name(m.host_name) {
			$found = $found.append(
				"HostName ${m.host_name} is no host name; "
					.concat("use letters, digits, - or _"),
			)
		}
		if !m.host.is_empty() and !MachineModel.valid_target(m.host) {
			$found = $found.append(
				"Host ${m.host} is no SSH target; ${MachineModel.target_form}",
			)
		}
		if !Machine.valid_time_zone(m.time_zone) {
			$found = $found.append(
				"TimeZone ${m.time_zone} is no time zone, such as \"Etc/UTC\"",
			)
		}
		for name in Machine.repeated(m.users.map(|u| u.name)) {
			$found = $found.append("user ${name} is declared more than once")
		}
		for u in m.users {
			if !MachineModel.valid_account(u.name) {
				$found = $found.append("user ${u.name} is no user name")
			}
			if u.name == "root" and !u.groups.is_empty() {
				$found = $found.append("root takes no Groups")
			}
			for group in u.groups.drop_if(MachineModel.valid_account) {
				$found = $found.append("user ${u.name}: ${group} is no group name")
			}
			for key in u.keys.drop_if(Machine.valid_ssh_key) {
				$found = $found.append(
					"user ${u.name}: \"${key}\" is no SSH public key",
				)
			}
		}
		if m.ssh and !m.users.any(|u| !u.keys.is_empty()) {
			# Only keys log in.
			$found = $found.append("Ssh needs a User with SshKeys")
		}
		match m.disk {
			SingleDisk(device) if !Machine.valid_device(device) => {
				$found = $found.append(
					"Disk device ${device} is no /dev/... path, such as \"/dev/sda\"",
				)
			}
			_ => {}
		}
		for operator in m.operators.drop_if(Machine.valid_operator) {
			$found = $found.append(
				"operator \"${operator}\" is no age recipient or ssh-ed25519 or "
					.concat("ssh-rsa public key"),
			)
		}
		if !m.secrets.is_empty() and m.operators.is_empty() {
			$found = $found.append("Secrets needs Operators to encrypt them to")
		}
		for name in Machine.repeated(m.secrets.map(|s| s.name)) {
			$found = $found.append("secret ${name} is declared more than once")
		}
		for s in m.secrets {
			if !Machine.valid_secret_name(s.name) {
				$found = $found.append(
					"secret ${s.name} is no secret name; use a letter, then "
						.concat("letters, digits, -, _ or ."),
				)
			}
			if !MachineModel.valid_account(s.owner) {
				$found = $found.append("secret ${s.name}: ${s.owner} is no user name")
			}
			if !MachineModel.valid_account(s.group) {
				$found = $found.append("secret ${s.name}: ${s.group} is no group name")
			}
			if !Machine.valid_mode(s.mode) {
				$found = $found.append(
					"secret ${s.name}: Mode ${s.mode} is no octal mode, such as \"0400\"",
				)
			}
		}
		if m.tcp_ports.concat(m.udp_ports).contains(0) {
			$found = $found.append("Firewall ports run from 1 to 65535")
		}
		if !m.environment.is_empty() {
			match model.environments.find_first(|e| e.name == m.environment) {
				Err(_) => {
					$found = $found.append("Use names no environment: ${m.environment}")
				}
				Ok(environment) if StdModel.direct_only(model, environment) => {
					$found = $found.append(
						"environment ${m.environment} needs the direct backend",
					)
				}
				Ok(_) => {}
			}
		}
		$found
	}

	letter : U8 -> Bool
	letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

	digit : U8 -> Bool
	digit = |b| b >= '0' and b <= '9'

	## A letter, then letters, digits, - or _: a subcommand and a bare Nix
	## attribute name.
	valid_machine_name : Str -> Bool
	valid_machine_name = |name|
		match name.to_utf8() {
			[first, .. as rest] =>
				Machine.letter(first)
					and rest.all(
						|b| Machine.letter(b) or Machine.digit(b) or b == '-' or b == '_',
					)
			[] => Bool.False
		}

	## NixOS's networking.hostName: up to 63 letters, digits, - or _,
	## starting and ending with a letter or digit.
	valid_host_name : Str -> Bool
	valid_host_name = |name| {
		bytes = name.to_utf8()
		alphanumeric = |b| Machine.letter(b) or Machine.digit(b)
		ends = match (bytes.first(), bytes.last()) {
			(Ok(first), Ok(last)) => alphanumeric(first) and alphanumeric(last)
			_ => Bool.False
		}
		ends
			and bytes.len() <= 63
			and bytes.all(|b| alphanumeric(b) or b == '-' or b == '_')
	}

	## A device's absolute path beneath /dev, such as "/dev/sda" or
	## "/dev/disk/by-id/...": letters, digits and `._:+-` in segments that
	## are neither `.` nor `..`.
	valid_device : Str -> Bool
	valid_device = |device| {
		plain = |b|
			Machine.letter(b) or Machine.digit(b) or "._:+-".to_utf8().contains(b)
		segments = device.drop_prefix("/dev/").split_on("/")
		device.starts_with("/dev/")
			and segments.all(
				|s| !s.is_empty() and s != "." and s != ".." and s.to_utf8().all(plain),
			)
	}

	## Empty, for NixOS's default, or a zone name such as "Europe/Berlin".
	valid_time_zone : Str -> Bool
	valid_time_zone = |zone|
		zone.to_utf8().all(
			|b| Machine.letter(b) or Machine.digit(b) or "/_+-".to_utf8().contains(b),
		)

	## A NixOS release such as "25.05".
	valid_state_version : Str -> Bool
	valid_state_version = |version| {
		two_digits = |part|
			part.count_utf8_bytes() == 2 and part.to_utf8().all(Machine.digit)
		match version.split_on(".") {
			[year, month] => two_digits(year) and two_digits(month)
			_ => Bool.False
		}
	}

	## An OpenSSH public key line: its type, its base64 key and an optional
	## comment.
	valid_ssh_key : Str -> Bool
	valid_ssh_key = |key| {
		types = [
			"ssh-ed25519",
			"ssh-rsa",
			"ecdsa-sha2-nistp256",
			"ecdsa-sha2-nistp384",
			"ecdsa-sha2-nistp521",
			"sk-ssh-ed25519@openssh.com",
			"sk-ecdsa-sha2-nistp256@openssh.com",
		]
		base64 = |b|
			Machine.letter(b) or Machine.digit(b) or b == '+' or b == '/' or b == '='
		one_line = key.to_utf8().all(|b| b >= 32 and b != 127)
		match key.split_on(" ") {
			[kind, data, ..] =>
				one_line
					and types.contains(kind)
					and data.count_utf8_bytes() >= 16
					and data.to_utf8().all(base64)
			_ => Bool.False
		}
	}

	## A key age encrypts to: an X25519 recipient, `age1` and 58 bech32
	## characters, or an ssh-ed25519 or ssh-rsa public key.
	valid_operator : Str -> Bool
	valid_operator = |key|
		match key.split_first(" ") {
			Ok({ before, .. }) =>
				["ssh-ed25519", "ssh-rsa"].contains(before) and Machine.valid_ssh_key(key)
			Err(_) => {
				bech32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l".to_utf8()
				data = key.drop_prefix("age1")
				key.starts_with("age1")
					and data.count_utf8_bytes() == 58
					and data.to_utf8().all(|b| bech32.contains(b))
			}
		}

	## A secret's name, its file's under secrets/ and /run/secrets: a letter,
	## then letters, digits, `-`, `_` or `.`.
	valid_secret_name : Str -> Bool
	valid_secret_name = |name| {
		plain = |b|
			Machine.letter(b) or Machine.digit(b) or "-_.".to_utf8().contains(b)
		match name.to_utf8() {
			[first, .. as rest] => Machine.letter(first) and rest.all(plain)
			[] => Bool.False
		}
	}

	## An octal file mode such as "0400" or "640": three or four of 0 to 7.
	valid_mode : Str -> Bool
	valid_mode = |mode| {
		bytes = mode.to_utf8()
		octal = bytes.all(|b| b >= '0' and b <= '7')
		(bytes.len() == 3 or bytes.len() == 4) and octal
	}
}

import pf.Implementation
import pf.Layout
import pf.Plan
import std.Std

# The flake.lock nix flake update writes for the project's nixpkgs.
flake_lock =
	\\{
	\\  "nodes": {
	\\    "default": {
	\\      "locked": {
	\\        "lastModified": 1790185690,
	\\        "narHash": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=",
	\\        "owner": "NixOS",
	\\        "repo": "nixpkgs",
	\\        "rev": "4975466d324710c576dc11ad614684e6bd8cad8e",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "NixOS", "ref": "nixos-unstable",
	\\        "repo": "nixpkgs", "type": "github"
	\\      }
	\\    },
	\\    "root": { "inputs": { "default": "default" } }
	\\  },
	\\  "root": "root",
	\\  "version": 7
	\\}

# The flake.lock nix flake update writes for the project's nixpkgs and
# disko, whose own nixpkgs is locked apart.
disko_lock =
	\\{
	\\  "nodes": {
	\\    "default": {
	\\      "locked": {
	\\        "lastModified": 1790185690,
	\\        "narHash": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=",
	\\        "owner": "NixOS",
	\\        "repo": "nixpkgs",
	\\        "rev": "4975466d324710c576dc11ad614684e6bd8cad8e",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "NixOS", "ref": "nixos-unstable",
	\\        "repo": "nixpkgs", "type": "github"
	\\      }
	\\    },
	\\    "disko": {
	\\      "inputs": { "nixpkgs": "nixpkgs" },
	\\      "locked": {
	\\        "lastModified": 1790100000,
	\\        "narHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
	\\        "owner": "nix-community",
	\\        "repo": "disko",
	\\        "rev": "0123456789abcdef0123456789abcdef01234567",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "nix-community", "repo": "disko", "type": "github"
	\\      }
	\\    },
	\\    "nixpkgs": {
	\\      "locked": {
	\\        "lastModified": 1790185690,
	\\        "narHash": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=",
	\\        "owner": "NixOS",
	\\        "repo": "nixpkgs",
	\\        "rev": "4975466d324710c576dc11ad614684e6bd8cad8e",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "NixOS", "ref": "nixpkgs-unstable",
	\\        "repo": "nixpkgs", "type": "github"
	\\      }
	\\    },
	\\    "root": { "inputs": { "default": "default", "disko": "disko" } }
	\\  },
	\\  "root": "root",
	\\  "version": 7
	\\}

project : List(Config.Setting)
project = [
	Name("site"),
	Systems(["x86_64-linux"]),
	Environment("ops", [Tools(["htop"])]),
]

key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 admin@example"

web : List(MachineSetting)
web = [
	System("x86_64-linux"),
	StateVersion("25.05"),
	User("admin", [SshKeys([key]), Groups(["wheel"])]),
	Ssh,
	Firewall([Tcp([80, 443])]),
	Use("ops"),
	Modules(["nixos/web.nix"]),
]

context : Implementation.Context
context = {
	args: [],
	backend: "nix",
	host: { system: "x86_64-linux" },
	layout: Layout.{
		project_root: "/project",
		workspace: "/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	},
	revision: { describe: "", commit_date: "" },
	lock: Absent,
	phase: 0,
	observed: [],
}

# The project with disko declared, which a machine with a Disk needs.
disko_project = project.append(Input("disko", "github:nix-community/disko"))

# The lock std's update publishes for `settings` from Nix's `nix_lock`.
published : List(Config.Setting), Str -> [Absent, Present(Str)]
published = |settings, nix_lock| {
	observed = [{ path: "/generated/nix/flake.lock", contents: Text(nix_lock) }]
	resumed = { ..context, phase: 1, observed }
	update = Std.plugin(settings).implementations
		.find_first(|i| i.command == "update" and i.backend == On("nix"))
	match update.map_ok(|i| (i.plan)(resumed)) {
		Ok(Ok({ steps: [PublishLock({ contents, .. }), ..], .. })) =>
			Present(contents)
		_ => Absent
	}
}

# The plan of `kai machine ACTION web` on a host of `system`, after the
# implementation fits.
planned : Str, Str -> Try(Plan, Plan.Failure)
planned = |action, system| planned_with(web, action, system, "")

# The plan of `kai machine ACTION web --to TO` ("" for no --to) for machine
# web's `settings`, on a host of `system`.
planned_with : List(MachineSetting), Str, Str, Str -> Try(Plan, Plan.Failure)
planned_with = |settings, action, system, to| {
	locked = { settings: project, nix_lock: flake_lock, system }
	planned_in(locked, settings, action, to)
}

# std's `settings` locked from Nix's `nix_lock`, on a host of `system`.
Locked : { settings : List(Config.Setting), nix_lock : Str, system : Str }

# The plan of `kai machine ACTION web --to TO` in a locked project, for
# machine web's `machine_settings`.
planned_in : Locked, List(MachineSetting), Str, Str -> Try(Plan, Plan.Failure)
planned_in = |locked, machine_settings, action, to| {
	{ settings, nix_lock, system } = locked
	plugin = Machine.plugin(settings, [Machine("web", machine_settings)])
	options = if (to.is_empty()) [] else [{ name: "to", value: Present(to) }]
	args = [{ name: "action", value: Present(action) }]
		.append({ name: "machine", value: Many(["web"]) })
		.concat(options)
	found = plugin.implementations
		.first()
		.map_err(|_| Plan.fail("no implementation"))?
	(found.fit)(args).map_err(Plan.fail)?
	lock = published(settings, nix_lock)
	(found.plan)({ ..context, args, host: { system: system }, lock })
}

# Whether machine web's rendered lines, trimmed, hold `expected` in order.
renders : List(MachineSetting), List(Str) -> Bool
renders = |settings, expected| {
	rendered = NixosBackend.outputs([Machine.machine("web", settings)], "/project")
	remaining = rendered
		.split_on("\n")
		.map(Str.trim)
		.fold(
			expected,
			|wanted, line|
				match wanted {
					[first, .. as rest] if first == line => rest
					_ => wanted
				},
		)
	remaining.is_empty()
}

# The problems the plugin reports for machine web's settings.
problems_of : List(MachineSetting) -> List(Str)
problems_of = |settings|
	Machine.plugin(project, [Machine("web", settings)]).problems

# Machine web as it installs: with a Disk, in the project with disko.
installed_web = web.append(Disk(SingleDisk("/dev/sda")))

# The plan of `kai machine install web --to TO` ("" for no --to) for machine
# web's `settings` in the project with disko.
installed : List(MachineSetting), Str -> Try(Plan, Plan.Failure)
installed = |settings, to| {
	system = "x86_64-linux"
	locked = { settings: disko_project, nix_lock: disko_lock, system }
	planned_in(locked, settings, "install", to)
}

# An install expects nix and ssh, builds as `build` does, confirms naming
# the target and the disk it erases, then runs nixos-anywhere from the
# project's locked nixpkgs on the generated flake, read impurely as a build
# reads it.
expect {
	target = "root@203.0.113.7"
	flake = "path:/generated/nix"
	anywhere = ["--flake", "${flake}#web", "--target-host", target]
	toplevel = "nixosConfigurations.web.config.system.build.toplevel"
	match installed(installed_web, target) {
		Ok({ steps, next: Done }) =>
			match steps {
				[ExpectPrograms(tools), CheckSource(_), .. as rest] =>
					tools.programs == ["nix", "ssh"]
						and match rest.drop_first(1) {
							[Run(built), Confirm(prompt), Run(install)] =>
								built.argv.last() == Ok("${flake}#${toplevel}")
									and prompt
										== "Install machine web on ${target}, ERASING its disk "
											.concat("/dev/sda and everything on it?")
									and match install.argv {
										["sh", "-c", script, "sh", .. as given] =>
											given == [flake].concat(anywhere)
												and script.contains("\$NIX_CONFIG\npure-eval = false")
												and script.contains("default#nixos-anywhere")
												and !script.contains(target)
										_ => Bool.False
									}
							_ => Bool.False
						}
				_ => Bool.False
			}
		_ => Bool.False
	}
}

# An install goes only where --to says, never to Host, and refuses a
# machine without a Disk to partition or without SSH logins to reach it by
# afterwards.
expect {
	refused = |settings, to|
		match installed(settings, to) {
			Err({ message, .. }) => message
			Ok(_) => ""
		}
	target = "root@203.0.113.7"
	no_ssh = installed_web.drop_if(|s| Machine.setting_name(s) == "Ssh")
	no_disk = web
	refused(installed_web.append(Host("admin@web.example.com")), "")
		== "kai machine install web needs --to TARGET, such as root@203.0.113.7: "
			.concat("it erases the target's disk, so it never defaults to Host")
		and refused(no_disk, target)
			== "kai machine install needs Disk(...) on machine web, the disk it "
				.concat("partitions and installs on")
		and refused(no_ssh, target)
			== "kai machine install needs Ssh and a User with SshKeys on machine "
				.concat("web, or the server cannot be reached once installed")
		and refused(installed_web, "-oProxyCommand=x")
			== "--to -oProxyCommand=x is no SSH target; ${MachineModel.target_form}"
}

# A Disk renders disko's module and nixos-anywhere's layout on the device:
# a BIOS boot partition, an EFI system partition at /boot and an ext4 root,
# with GRUB installed for BIOS and UEFI. Without a Disk, neither renders.
expect {
	layout = [
		"imports = [ inputs.\"disko\".nixosModules.disko ];",
		"disko.devices.disk.main = {",
		"type = \"disk\";",
		"device = \"/dev/sda\";",
		"type = \"gpt\";",
		"boot = { size = \"1M\"; type = \"EF02\"; };",
		"size = \"512M\";",
		"type = \"EF00\";",
		"format = \"vfat\";",
		"mountpoint = \"/boot\";",
		"size = \"100%\";",
		"format = \"ext4\";",
		"mountpoint = \"/\";",
		"boot.loader.grub = {",
		"efiSupport = true;",
		"efiInstallAsRemovable = true;",
	]
	renders(installed_web, layout)
		and !renders(web, ["disko.devices.disk.main = {"])
		and !renders(web, ["efiSupport = true;"])
}

# A Disk is a /dev path of plain characters, given once, and needs disko
# declared in std's settings; each is refused as Kaifile.roc compiles.
expect {
	in_disko = |settings|
		Machine.plugin(disko_project, [Machine("web", settings)]).problems
	disk = |device| Disk(SingleDisk(device))
	declare = "add Input(\"disko\", \"github:nix-community/disko\")"
	bad = |device|
		"machine web: Disk device ${device} is no /dev/... path, "
			.concat("such as \"/dev/sda\"")
	valid = ["/dev/sda", "/dev/nvme0n1", "/dev/disk/by-path/pci-0000:00:04.0"]
	invalid = ["sda", "/dev/", "/dev/../etc/passwd", "/dev/sd a", "/dev/x;y"]
	in_disko(installed_web) == []
		and valid.all(Machine.valid_device)
		and !invalid.any(Machine.valid_device)
		and in_disko(web.append(disk("/dev/sd\"a"))) == [bad("/dev/sd\"a")]
		and in_disko(web.concat([disk("/dev/sda"), disk("/dev/sdb")]))
			== ["machine web: Disk is given more than once"]
		and problems_of(installed_web)
			== ["machine web: Disk needs disko; ${declare} to std's settings"]
}

# A build checks the machine's modules, writes std's flake with the machine
# in nixosConfigurations, and builds its toplevel, printing the store path.
expect {
	toplevel = "nixosConfigurations.web.config.system.build.toplevel"
	outputs = NixosBackend.outputs([Machine.machine("web", web)], "/project")
	match planned("build", "x86_64-linux").map_ok(|plan| plan.steps) {
		Ok([CheckSource(checked), Write([flake, ..]), Run({ argv, output, .. })]) =>
			checked == "/project/nixos/web.nix"
				and flake.contents.contains(outputs)
				and argv.last() == Ok("path:/generated/nix#${toplevel}")
				and argv.contains("--no-link")
				and output == Artifact({ name: "web", label: toplevel, output: "out" })
		_ => Bool.False
	}
}

# NixOS's system profile, and machine web as its settings fold.
profile = NixosBackend.profile

web_machine = Machine.machine("web", web)

# Run steps' argv, in order.
argvs : List(Plan.Step) -> List(List(Str))
argvs = |steps|
	steps.keep_oks(
		|step|
			match step {
				Run({ argv, .. }) => Ok(argv)
				_ => Err({})
			},
	)

# A switch checks the host first, builds as `build` does but leaves an
# out-link, confirms, then sets the system profile to it and activates it as
# root. The whole plan is known up front, so --dry-run prints all of it.
expect {
	activate = ["sudo", "${profile}/bin/switch-to-configuration", "switch"]
	link = "/work/machines/web"
	set = ["sudo", "nix", "build", "--no-link", "--profile", profile, link]
	plan = planned("switch", "x86_64-linux")
	done = plan.map_ok(|p| p.next) == Ok(Done)
	match plan.map_ok(|p| p.steps) {
		Ok([Run(check), _, _, Run(built), Confirm(prompt), .. as rest]) =>
			done
				and check.argv == NixosBackend.host_check("switch", web_machine)
				and built.argv.contains("--out-link")
				and built.argv.contains(link)
				and !built.argv.contains("--no-link")
				and prompt.starts_with("Switch this host to machine web,")
				and argvs(rest) == [set, activate]
		_ => Bool.False
	}
}

# A rollback checks the host and confirms before rolling the profile back and
# activating it; generations only lists, with nothing to confirm or run as
# root.
expect {
	activate = ["sudo", "${profile}/bin/switch-to-configuration", "switch"]
	back = ["sudo", "nix", "profile", "rollback", "--profile", profile]
	rolled_back = match planned("rollback", "x86_64-linux") {
		Ok({ steps: [Run(check), Confirm(_), .. as rest], next: Done }) =>
			check.argv == NixosBackend.host_check("rollback", web_machine)
				and argvs(rest) == [back, activate]
		_ => Bool.False
	}
	listed = match planned("generations", "x86_64-linux") {
		Ok({ steps: [Run(_), Run({ argv, .. })], next: Done }) =>
			argv == ["nixos-rebuild", "list-generations"]
		_ => Bool.False
	}
	rolled_back and listed
}

# Each refuses a host of another system before planning anything, and checks
# the host's name, the machine's HostName, as it runs: the names and the
# message are the script's arguments, never part of it.
expect {
	other = |action|
		match planned(action, "aarch64-linux") {
			Err({ message, .. }) =>
				message
					== "machine web is x86_64-linux, but this host is aarch64-linux: "
						.concat(NixosBackend.local_only(action, Machine.machine("web", web)))
			Ok(_) => Bool.False
		}
	www = Machine.machine("web", web.append(HostName("www")))
	checked = match NixosBackend.host_check("switch", www) {
		["sh", "-c", script, "sh", "www", why] =>
			!script.contains("www")
				and why
					== "kai machine switch without Host or --to acts on the host it "
						.concat("runs on; run it on www, or name its SSH target with ")
						.concat("Host or --to")
		_ => Bool.False
	}
	["switch", "rollback", "generations"].all(other) and checked
}

# Machine web living at an SSH target, and the remote nix command.
remote_web = web.append(Host("admin@web.example.com"))

remote_nix = ["nix", "--extra-experimental-features", "nix-command"]

# A remote switch expects nix and ssh, checks the target, builds here as a
# local switch does, confirms naming the target, copies the system there,
# sets its profile to the store path and activates it, through sudo for a
# user other than root.
expect {
	target = "admin@web.example.com"
	link = "/work/machines/web"
	copy = ["nix", "copy", "--substitute-on-destination", "--to"]
		.concat(["ssh-ng://${target}", link])
	profile_command = ["sudo"]
		.concat(remote_nix)
		.concat(["build", "--no-link", "--profile", profile])
	set = NixosBackend.remote_profile(link, target, profile_command)
	activate = ["ssh", target, "--", "sudo"]
		.concat(["${profile}/bin/switch-to-configuration", "switch"])
	machine = Machine.machine("web", remote_web)
	match planned_with(remote_web, "switch", "x86_64-linux", "") {
		Ok({ steps, next: Done }) =>
			match steps {
				[ExpectPrograms(tools), Run(check), _, _, Run(built), .. as rest] =>
					tools.programs == ["nix", "ssh"]
						and check.argv == NixosBackend.remote_check(machine, target)
						and built.argv.contains(link)
						and match rest {
							[Confirm(prompt), ..] =>
								prompt.starts_with("Switch ${target} to machine web,")
							_ => Bool.False
						}
						and argvs(rest) == [copy, set, activate]
						and set.last()
							== Ok(
								"sudo nix --extra-experimental-features nix-command build "
									.concat("--no-link --profile ${profile}"),
							)
				_ => Bool.False
			}
		_ => Bool.False
	}
}

# --to overrides Host; as root, a remote rollback and listing run nothing
# through sudo. Rollback confirms first; generations only lists.
expect {
	target = "root@203.0.113.7"
	on_target = |argv| ["ssh", target, "--"].concat(argv)
	back = on_target(
		remote_nix.concat(["profile", "rollback", "--profile", profile]),
	)
	activate = on_target(["${profile}/bin/switch-to-configuration", "switch"])
	on = |action| planned_with(remote_web, action, "x86_64-linux", target)
	rolled_back = match on("rollback").map_ok(|plan| plan.steps) {
		Ok([ExpectPrograms(tools), Run(check), Confirm(prompt), .. as rest]) =>
			tools.programs == ["ssh"]
				and check.argv.get(4) == Ok(target)
				and prompt.starts_with("Switch ${target} back")
				and argvs(rest) == [back, activate]
		_ => Bool.False
	}
	listed = match on("generations") {
		Ok({ steps: [ExpectPrograms(_), Run(_), Run({ argv, .. })], next: Done }) =>
			argv == on_target(["nixos-rebuild", "list-generations"])
		_ => Bool.False
	}
	rolled_back and listed
}

# The remote check passes the target, architecture and messages as the
# script's arguments, and the profile step quotes its command for the remote
# shell while the store path stays an argument too.
expect {
	target = "admin@web.example.com"
	machine = Machine.machine("web", remote_web)
	checked = match NixosBackend.remote_check(machine, target) {
		["sh", "-c", script, "sh", "admin@web.example.com", "x86_64", is, then] =>
			!script.contains(target)
				and is == "machine web is x86_64-linux"
				and then == "run kai machine install web --to ${target} first"
		_ => Bool.False
	}
	command = ["a b", "it's", "c"]
	set = match NixosBackend.remote_profile("/work/x", target, command) {
		["sh", "-c", script, "sh", "/work/x", "admin@web.example.com", quoted] =>
			!script.contains(target) and quoted == "'a b' 'it'\\''s' c"
		_ => Bool.False
	}
	checked and set
}

# A build stays here: it ignores Host and refuses --to, and a --to that is no
# SSH target is refused before planning.
expect {
	refused = |action, to|
		match planned_with(remote_web, action, "x86_64-linux", to) {
			Err({ message, .. }) => message
			Ok(_) => ""
		}
	built = match planned_with(remote_web, "build", "x86_64-linux", "") {
		Ok({ steps: [CheckSource(_), Write(_), Run(_)], .. }) => Bool.True
		_ => Bool.False
	}
	built
		and refused("build", "root@203.0.113.7")
			== "kai machine build builds here and takes no --to"
		and refused("switch", "-oProxyCommand=x")
			== "--to -oProxyCommand=x is no SSH target; ${MachineModel.target_form}"
}

# SSH targets are a host, a name or an IPv4 or IPv6 address, after an
# optional account name; never an option, a port, spaces or control
# characters. A bad Host is refused as Kaifile.roc compiles.
expect {
	valid = ["web", "root@203.0.113.7", "admin@web.example.com"]
		.append("root@2001:db8::1")
	invalid = [
		"",
		"-oProxyCommand=x",
		"admin@-web",
		"Admin@web",
		"@web",
		"admin@",
		"web:22",
		"web example",
		"web\n",
		"a@b@c",
	]
	required = [System("x86_64-linux"), StateVersion("25.05")]
	valid.all(MachineModel.valid_target)
		and !invalid.any(MachineModel.valid_target)
		and problems_of(required.append(Host("web:22")))
			== ["machine web: Host web:22 is no SSH target; ${MachineModel.target_form}"]
		and problems_of(required.append(Host("")))
			== ["machine web: Host is empty; ${MachineModel.target_form}"]
		and problems_of(required.concat([Host("a"), Host("b")]))
			== ["machine web: Host is given more than once"]
}

# Host's user, when declared and not root, is trusted to copy systems in.
expect {
	trusted = |user| "nix.settings.trusted-users = [ \"root\" \"${user}\" ];"
	renders(remote_web, [trusted("admin")])
		and !renders(web.append(Host("root@web")), [trusted("root")])
		and !renders(web.append(Host("deploy@web")), [trusted("deploy")])
}

# A machine is nixosSystem of the default source: one module of its typed
# settings, then its own module files by absolute path.
expect
	renders(
		web,
		[
			"nixosConfigurations = {",
			"\"web\" = inputs.\"default\".lib.nixosSystem {",
			"specialArgs = { inherit inputs; };",
			"nixpkgs.hostPlatform = \"x86_64-linux\";",
			"networking.hostName = \"web\";",
			"system.stateVersion = \"25.05\";",
			"users.users.\"admin\" = {",
			"isNormalUser = true;",
			"extraGroups = [ \"wheel\" ];",
			"openssh.authorizedKeys.keys = [ \"${key}\" ];",
			"services.openssh = {",
			"settings.PasswordAuthentication = false;",
			"settings.KbdInteractiveAuthentication = false;",
			"settings.PermitRootLogin = \"no\";",
			"networking.firewall.allowedTCPPorts = [ 80 443 ];",
			"environment.systemPackages =",
			"((environmentsFor \"x86_64-linux\").\"ops\" { }).nativeBuildInputs;",
			"(/. + \"/project/nixos/web.nix\")",
		],
	)

# Root logs in with its keys only, and is no ordinary user; HostName and
# TimeZone replace NixOS's defaults.
expect {
	root = [
		System("x86_64-linux"),
		User("root", [SshKeys([key])]),
		Ssh,
		HostName("www"),
		TimeZone("Etc/UTC"),
	]
	renders(
		root,
		[
			"networking.hostName = \"www\";",
			"time.timeZone = \"Etc/UTC\";",
			"users.users.root.openssh.authorizedKeys.keys = [ \"${key}\" ];",
			"settings.PermitRootLogin = \"prohibit-password\";",
		],
	)
		and !renders(root, ["isNormalUser = true;"])
}

# An unknown machine, or none, is refused before planning.
expect {
	machines = [Machine.machine("web", web)]
	db = [{ name: "machine", value: Many(["db"]) }]
	MachineModel.requested(machines, db) == Err("unknown machine: db")
		and MachineModel.requested(machines, []) == Err(MachineModel.name_one)
}

# Settings are checked as Kaifile.roc compiles: systems, users, keys, the
# environment and module paths, and settings given twice.
expect {
	required = [System("x86_64-linux"), StateVersion("25.05")]
	bad_user = User("Admin", [SshKeys(["ssh-ed25519 short"])])
	checks = [
		(web, []),
		([StateVersion("25.05")], ["System is required"]),
		(
			[System("x86_64-darwin"), StateVersion("25.05")],
			["System x86_64-darwin is not x86_64-linux or aarch64-linux"],
		),
		(
			[System("aarch64-linux"), StateVersion("25.05")],
			["System aarch64-linux is not among the project's Systems"],
		),
		(
			[System("x86_64-linux"), StateVersion("25")],
			["StateVersion is required, as a release such as \"25.05\""],
		),
		(
			required.append(bad_user),
			[
				"user Admin is no user name",
				"user Admin: \"ssh-ed25519 short\" is no SSH public key",
			],
		),
		(required.append(Ssh), ["Ssh needs a User with SshKeys"]),
		(
			required.concat([Use("dev"), Modules(["../web.nix", "/web.nix"])]),
			[
				"Use names no environment: dev",
				"module ../web.nix is no .nix file inside the project",
				"module /web.nix is no .nix file inside the project",
			],
		),
		(
			required.concat([TimeZone("UTC"), TimeZone("Etc/UTC")]),
			["TimeZone is given more than once"],
		),
	]
	twice = Machine.plugin(project, [Machine("web", web), Machine("web", web)])
	checks.all(
		|(settings, expected)|
			problems_of(settings) == expected.map(|p| "machine web: ${p}"),
	)
		and twice.problems == ["machine web is declared more than once"]
}

# The flake.lock nix flake update writes for the project's nixpkgs, disko
# and agenix, whose own nixpkgs are locked apart.
agenix_lock =
	\\{
	\\  "nodes": {
	\\    "default": {
	\\      "locked": {
	\\        "lastModified": 1790185690,
	\\        "narHash": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=",
	\\        "owner": "NixOS",
	\\        "repo": "nixpkgs",
	\\        "rev": "4975466d324710c576dc11ad614684e6bd8cad8e",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "NixOS", "ref": "nixos-unstable",
	\\        "repo": "nixpkgs", "type": "github"
	\\      }
	\\    },
	\\    "disko": {
	\\      "inputs": { "nixpkgs": "nixpkgs" },
	\\      "locked": {
	\\        "lastModified": 1790100000,
	\\        "narHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
	\\        "owner": "nix-community",
	\\        "repo": "disko",
	\\        "rev": "0123456789abcdef0123456789abcdef01234567",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "nix-community", "repo": "disko", "type": "github"
	\\      }
	\\    },
	\\    "agenix": {
	\\      "inputs": { "nixpkgs": "nixpkgs" },
	\\      "locked": {
	\\        "lastModified": 1790100000,
	\\        "narHash": "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",
	\\        "owner": "ryantm",
	\\        "repo": "agenix",
	\\        "rev": "89abcdef0123456789abcdef0123456789abcdef",
	\\        "type": "github"
	\\      },
	\\      "original": { "owner": "ryantm", "repo": "agenix", "type": "github" }
	\\    },
	\\    "nixpkgs": {
	\\      "locked": {
	\\        "lastModified": 1790185690,
	\\        "narHash": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=",
	\\        "owner": "NixOS",
	\\        "repo": "nixpkgs",
	\\        "rev": "4975466d324710c576dc11ad614684e6bd8cad8e",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "NixOS", "ref": "nixpkgs-unstable",
	\\        "repo": "nixpkgs", "type": "github"
	\\      }
	\\    },
	\\    "root": {
	\\      "inputs": {
	\\        "default": "default", "disko": "disko", "agenix": "agenix"
	\\      }
	\\    }
	\\  },
	\\  "root": "root",
	\\  "version": 7
	\\}

# The project with disko and agenix declared, as a machine with Secrets
# needs, locked on an x86_64-linux host.
agenix_project = disko_project.append(Input("agenix", "github:ryantm/agenix"))

agenix_locked = {
	settings: agenix_project,
	nix_lock: agenix_lock,
	system: "x86_64-linux",
}

# An age recipient: age1, then 58 bech32 characters.
operator = "age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce"

# Machine web as it installs, with Operators and a secret its admin owns.
secret_web = installed_web.concat(
	[Operators([operator, key]), Secrets([Secret("app-key", [Owner("admin")])])],
)

# The plan of `kai secret ACTION WORDS...` for machine web's `settings`,
# with `identity` as --identity ("" for none).
secret_planned :
	List(MachineSetting), Str, List(Str), Str -> Try(Plan, Plan.Failure)
secret_planned = |settings, action, words, identity| {
	plugin = Machine.plugin(agenix_project, [Machine("web", settings)])
	option = { name: "identity", value: Present(identity) }
	given = if (identity.is_empty()) [] else [option]
	args = [{ name: "action", value: Present(action) }]
		.append({ name: "names", value: Many(words) })
		.concat(given)
	found = plugin.implementations
		.find_first(|i| i.command == "secret")
		.map_err(|_| Plan.fail("no implementation"))?
	(found.fit)(args).map_err(Plan.fail)?
	lock = published(agenix_project, agenix_lock)
	(found.plan)({ ..context, args, lock })
}

# age and ssh-keygen from the locked nixpkgs, running a script.
with_age = ["nix", "shell", "--inputs-from", "path:/generated/nix"]
	.concat(["default#age", "default#openssh", "--command", "sh", "-c"])

# `kai secret set web app-key` writes std's flake, without building the
# machine, then encrypts stdin with age from the locked nixpkgs. The script
# receives every name and key as an argument, never in its text, and makes
# its temporary directory itself.
expect {
	operators = "${operator}\n${key}"
	match secret_planned(secret_web, "set", ["web", "app-key"], "") {
		Ok({ steps: [ExpectPrograms(tools), .. as rest], next: Done }) =>
			tools.programs == ["nix"]
				and rest.any(
					|step|
						match step {
							Write(_) => Bool.True
							_ => Bool.False
						},
				)
				and match argvs(rest) {
					[argv] =>
						match argv.split_at(with_age.len()) {
							{ before, others: [script, "sh", .. as given] } =>
								before == with_age
									and given
										== [
											"/project/secrets",
											"web",
											"app-key",
											operators,
											NixosBackend.without_host_key("web"),
										]
									and script.contains("mktemp -d")
									and script.contains("trap 'rm -rf \"$work\"' EXIT")
									and script.contains("age -R \"$work/recipients\"")
									and !script.contains("app-key")
									and !script.contains(operator)
							_ => Bool.False
						}
					_ => Bool.False
				}
		_ => Bool.False
	}
}

# `kai secret rekey web` decrypts with --identity, or ~/.ssh/id_ed25519 when
# it is not given, and encrypts the secrets and the host key again.
expect {
	given = |identity|
		match secret_planned(secret_web, "rekey", ["web"], identity) {
			Ok({ steps, next: Done }) =>
				match argvs(steps) {
					[argv] =>
						match argv.split_at(with_age.len() + 2) {
							{ before, others } =>
								before.drop_last(2) == with_age
									and before.last() == Ok("sh")
									and others.first() == Ok(identity)
									and others.drop_first(1).take_first(2)
										== ["/project/secrets", "web"]
									and match before.get(with_age.len()) {
										Ok(script) =>
											script.contains("identity=$HOME/.ssh/id_ed25519")
												and script.contains("reencrypt \"$secret\"")
												and script.contains("hosts/$name.age")
										Err(_) => Bool.False
									}
						}
					_ => Bool.False
				}
			_ => Bool.False
		}
	given("") and given("/keys/operator")
}

# Unknown machines and secrets are refused before planning, with the names
# they may have meant; so are a machine without Operators and a set naming
# no secret.
expect {
	refused = |settings, action, words|
		match secret_planned(settings, action, words, "") {
			Err(failure) => failure
			Ok(_) => Plan.fail("")
		}
	machine = refused(secret_web, "rekey", ["wbe"])
	secret = refused(secret_web, "set", ["web", "app-kye"])
	machine.code == "unknown_name"
		and machine.message == "unknown machine: wbe"
		and machine.suggestions == ["web"]
		and secret.code == "unknown_name"
		and secret.message == "machine web declares no secret app-kye"
		and secret.suggestions == ["app-key"]
		and refused(installed_web, "rekey", ["web"]).message
			== "machine web has no Operators to encrypt secrets to"
		and refused(secret_web, "set", ["web"]).message
			== "name what to set: kai secret set MACHINE SECRET, or kai secret "
				.concat("rekey MACHINE")
}

# With Operators, install runs nixos-anywhere inside one script under age and
# ssh-keygen from the locked nixpkgs: it decrypts or makes the host key in its
# own temporary directory and places it with --extra-files. The target and
# every name and key are arguments.
expect {
	target = "root@203.0.113.7"
	flake = "path:/generated/nix"
	match planned_in(agenix_locked, secret_web, "install", target) {
		Ok({ steps, next: Done }) =>
			match argvs(steps).last() {
				Ok(argv) =>
					match argv.split_at(with_age.len()) {
						{ before, others: [script, "sh", .. as given] } =>
							before == with_age
								and given
									== [flake, "", "/project/secrets", "web", "${operator}\n${key}"]
										.concat(["--flake", "${flake}#web", "--target-host", target])
								and script.contains("--extra-files \"$files\"")
								and script.contains("ssh-keygen -q -t ed25519 -N ''")
								and script.contains("age -d -i \"$identity\" -o \"$key\"")
								and script.contains("default#nixos-anywhere")
								and script.contains("pure-eval = false")
								and !script.contains(target)
								and !script.contains("exec ")
						_ => Bool.False
					}
				Err(_) => Bool.False
			}
		_ => Bool.False
	}
}

# A build of a machine with Secrets fails before building when a secret's
# file is missing, naming the command that sets it, and checks each file.
expect {
	file = "/project/secrets/web/app-key.age"
	match planned_in(agenix_locked, secret_web, "build", "") {
		Ok({ steps: [CheckSource(_), Run(found), CheckSource(checked), ..], .. }) =>
			checked == file
				and match found.argv {
					["sh", "-c", script, "sh", "web", given] =>
						given == file and script.contains("run kai secret set $name $secret")
					_ => Bool.False
				}
		_ => Bool.False
	}
}

# Secrets render agenix's module and one age.secrets entry each, decrypted
# with the host key into /run/secrets; disko's and agenix's modules are
# imported together.
expect {
	agenix = "inputs.\"agenix\".nixosModules.default"
	identities = "age.identityPaths = [ \"/etc/ssh/ssh_host_ed25519_key\" ];"
	only_secrets = web.concat(
		[Operators([operator]), Secrets([Secret("db", [])])],
	)
	renders(
		secret_web,
		[
			"imports = [ inputs.\"disko\".nixosModules.disko ${agenix} ];",
			identities,
			"age.secrets.\"app-key\" = {",
			"file = (/. + \"/project/secrets/web/app-key.age\");",
			"owner = \"admin\";",
			"group = \"root\";",
			"mode = \"0400\";",
			"path = \"/run/secrets/app-key\";",
		],
	)
		and renders(only_secrets, ["imports = [ ${agenix} ];", "owner = \"root\";"])
		and !renders(installed_web, [identities])
}

# Operators and Secrets are checked as Kaifile.roc compiles: keys, names,
# owners, groups and modes, duplicates, Secrets without Operators, and
# Secrets without the agenix input.
expect {
	in_agenix = |settings|
		Machine.plugin(agenix_project, [Machine("web", settings)]).problems
	installed_with = |settings| installed_web.concat(settings)
	bad_key = "ssh-ed25519 short"
	ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY="
	secret = |name, options| Secrets([Secret(name, options)])
	operators = Operators([operator])
	no_operator = |k|
		"operator \"${k}\" is no age recipient or ssh-ed25519 or ssh-rsa "
			.concat("public key")
	bad_options = [Owner("App"), Group("-x"), Mode("0800")]
	checks = [
		(installed_with([Operators([operator, key])]), []),
		(installed_with([Operators([])]), ["Operators needs at least one key"]),
		(
			installed_with([Operators([bad_key, ecdsa, "age1short"])]),
			[bad_key, ecdsa, "age1short"].map(no_operator),
		),
		(
			installed_with([secret("db", [])]),
			["Secrets needs Operators to encrypt them to"],
		),
		(
			installed_with([operators, secret("a/b", bad_options)]),
			[
				"secret a/b is no secret name; use a letter, then letters, "
					.concat("digits, -, _ or ."),
				"secret a/b: App is no user name",
				"secret a/b: -x is no group name",
				"secret a/b: Mode 0800 is no octal mode, such as \"0400\"",
			],
		),
		(
			installed_with([operators, Secrets([Secret("db", []), Secret("db", [])])]),
			["secret db is declared more than once"],
		),
		(
			installed_with([operators, secret("db", [Mode("0400"), Mode("0440")])]),
			["secret db: Mode is given more than once"],
		),
	]
	declare = "add Input(\"agenix\", \"github:ryantm/agenix\") to std's settings"
	without_agenix = Machine.plugin(
		disko_project,
		[Machine("web", installed_with([operators, secret("db", [])]))],
	)
	accepted = installed_with([operators, secret("app.env_1-x", [Mode("640")])])
	checks.all(
		|(settings, expected)|
			in_agenix(settings) == expected.map(|p| "machine web: ${p}"),
	)
		and in_agenix(accepted) == []
		and without_agenix.problems
			== ["machine web: Secrets needs agenix; ${declare}"]
}
