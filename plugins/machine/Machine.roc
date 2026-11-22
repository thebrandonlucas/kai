# The machine plugin: `Machine(name, [...])` settings beside std's, each a
# system from a small typed core, and the `kai machine` and `kai secret`
# commands, which NixosBackend implements on the nix backend from
# MachineModel.
import pf.Command
import pf.Implementation
import pf.Plugin
import std.Config
import std.EnvName
import std.StdModel exposing [Model]
import std.System
import services.Caddy
import MachineModel
import NixosBackend

Machine := [].{

	## A machine. On the nix backend it is a NixOS system, rendered as
	## `nixosConfigurations.<name>` in std's generated flake from its
	## "default" package source.
	Setting : [Machine(Str, List(MachineSetting))]

	## System and StateVersion are required, and every setting but User
	## occurs at most once. HostName defaults to the machine's name, or an
	## instance's. Host is the SSH target, `user@host` or `host`, that
	## switch, rollback and generations act on instead of the host kai runs
	## on, unless they name an instance. Ssh runs
	## OpenSSH with key logins only, root's only when root has keys. Firewall
	## opens ports beside OpenSSH's. Use puts a std environment's tools on
	## the system's PATH. Disk is the disk layout `kai machine install`
	## partitions, which the system mounts and boots from, its drivers from
	## the hardware facts the install records. Operators are the
	## age recipients or SSH public keys of whoever may decrypt the machine's
	## host key and Secrets, which `kai secret set` writes and the system
	## decrypts into /run/secrets. Services are the typed services it runs,
	## each at most once. Modules are NixOS module files relative to the
	## project, which receive the flake's `inputs`. InputModules, which may
	## repeat, are module files relative to a locked flake input that std's
	## settings declare or a plugin asks std to lock, such as a provider's
	## profiles.
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
		Services(List(ServiceSetting)),
		Modules(List(Str)),
		InputModules(Str, List(Str)),
	]

	## A typed service, whose settings, checks and model are its module's in
	## the services package. Caddy serves sites over HTTPS and opens TCP
	## ports 80 and 443 and UDP port 443.
	ServiceSetting : [Caddy(List(Caddy.Setting))]

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
	## use; a machine's System must be one of its Systems. Machines ask std
	## to lock the "default" package source they are built from, and disko
	## and agenix when a machine has a Disk or Secrets.
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
					.locking(NixosBackend.lock_requests(machines))
					.checking_lock_requests(
						|requested| Machine.undeclared_inputs(project, machines, requested),
					)
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
					help: "Act on this SSH target, user@host[:port], not the machine's Host; "
						.concat("install needs it, since it erases the target's disk."),
				}),
				Flag({
					name: "no-rollback",
					short: "",
					help: "switch: keep the new system even when it fails to activate, "
						.concat("comes up other than running, or cuts kai off."),
				}),
				Machine.instance,
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
			"kai machine install web --as demo --to root@198.51.100.4",
			"kai --dry-run machine switch web",
			"kai machine switch web --to admin@203.0.113.7",
			"kai machine switch web --no-rollback",
			"kai machine rollback web",
			"kai machine generations web",
		],
		config: [
			"Machine(\"web\", [System(\"x86_64-linux\"), StateVersion(\"25.05\"),",
			"  Host(\"admin@web.example.com\"),",
			"  User(\"admin\", [SshKeys([\"ssh-ed25519 AAAA...\"])]), Ssh,",
			"  Disk(SingleDisk(\"/dev/sda\")),                   # kai locks disko",
			"  Operators([\"age1...\"]),",
			"  Secrets([Secret(\"app-key\", [Owner(\"app\")])]),   # kai locks agenix",
			"  Services([Caddy([Site(\"example.com\",",
			"    ReverseProxy(\"localhost:8080\"))])]),",
			"  Modules([\"nixos/web.nix\"]),",
			"  InputModules(\"profiles\", [\"digitalocean.nix\"])]),",
		],
	}

	## The instance of a machine a command acts on: one server of several
	## installed from the same declaration, whose hardware facts, host key
	## and secrets are kept under its name instead of the machine's.
	instance : Command.Arg
	instance = Value({
		name: "as",
		short: "",
		help: "Act on this instance of the machine, one server of several, which "
			.concat("keeps its own facts, host key and secrets (default the machine)."),
	})

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
				Machine.instance,
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
			"printf %s \"$API_KEY\" | kai secret set web app-key --as demo",
		],
		config: [
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
				.drop_if(|s| s == "User" or s == "InputModules")
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
			# A service's own settings, folded, hide the ones given twice.
			services = parts.join_map(
				|part|
					match part {
						Services(list) => list
						_ => []
					},
			)
			service_names = services.map(|Caddy(_)| "Caddy")
			service_problems = services.join_map(|Caddy(caddy)| Caddy.problems(caddy))
			found = Machine.repeated(given.concat(service_names))
				.map(|s| "${s} is given more than once")
				.concat(service_problems)
				.concat(empty)
				.concat(if (empty_operators) [no_operator] else [])
				.concat(repeated_options)
				.concat(Machine.problems(model, m))
				.concat(NixosBackend.problems(m))
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

	## Each input InputModules names that neither std's settings `project`
	## declare nor a plugin asks std to lock, as a problem. Kaifile.roc's
	## check finds them once it knows every plugin's lock requests.
	undeclared_inputs :
		List(Config.Setting), Machines, List(Implementation.Requested) -> List(Str)
	undeclared_inputs = |project, machines, requested| {
		declared = match StdModel.from_settings(project) {
			Ok(model) => model.inputs.map(|input| input.name)
			Err(_) => []
		}
		locked = requested.join_map(
			|asked|
				match asked.request {
					Input(name, _, _) => [name]
					Source(_) => []
				},
		)
		known = declared.concat(locked)
		var $found = []
		for m in machines {
			for file in m.input_modules {
				problem = "machine ${m.name}: InputModules names input ${file.input}, "
					.concat("which neither std's settings declare nor a plugin locks; ")
					.concat("add Input(\"${file.input}\", ...) to them")
				if !known.contains(file.input) and !$found.contains(problem) {
					$found = $found.append(problem)
				}
			}
		}
		$found
	}

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
			Services(_) => "Services"
			Modules(_) => "Modules"
			InputModules(_, _) => "InputModules"
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
				instance: name,
				system: "",
				host_name: "",
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
				services: [],
				modules: [],
				input_modules: [],
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
					Services(services) => {
						..m,
						services: services.map(|Caddy(caddy)| Caddy(Caddy.server(caddy))),
					}
					Modules(modules) => { ..m, modules }
					InputModules(input, paths) => {
						..m,
						input_modules: m.input_modules.concat(
							paths.map(|path| { input, path }),
						),
					}
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
		host_name = MachineModel.host_name(m)
		if !Machine.valid_host_name(host_name) {
			$found = $found.append(
				"HostName ${host_name} is no host name; "
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

import pf.Layout
import pf.Plan
import pf.Kaifile
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

# The flake.lock nix flake update writes for the project's nixpkgs, disko
# and nixos-images, whose own nixpkgs follow the project's.
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
	\\      "inputs": { "nixpkgs": ["default"] },
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
	\\    "nixos-images": {
	\\      "inputs": {
	\\        "nixos-stable": ["default"], "nixos-unstable": ["default"]
	\\      },
	\\      "locked": {
	\\        "lastModified": 1790100000,
	\\        "narHash": "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=",
	\\        "owner": "nix-community",
	\\        "repo": "nixos-images",
	\\        "rev": "fedcba9876543210fedcba9876543210fedcba98",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "nix-community", "repo": "nixos-images", "type": "github"
	\\      }
	\\    },
	\\    "root": {
	\\      "inputs": {
	\\        "default": "default", "disko": "disko",
	\\        "nixos-images": "nixos-images"
	\\      }
	\\    }
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
	lock_requests: [],
}

# What plugins ask std to lock, each with the asking plugin's name.
Requests : List(Implementation.Requested)

# Every plugin's lock requests in a Kaifile of std for `settings` and the
# machine `plugin`.
requests_of : List(Config.Setting), Plugin -> Requests
requests_of = |settings, plugin|
	Kaifile.lock_requests(Kaifile.new([Std.plugin(settings), plugin]))

# The lock std's update publishes for `settings` and every plugin's
# `requests` from Nix's `nix_lock`.
published : List(Config.Setting), Requests, Str -> [Absent, Present(Str)]
published = |settings, requests, nix_lock| {
	observed = [{ path: "/generated/nix/flake.lock", contents: Text(nix_lock) }]
	resumed = { ..context, phase: 1, observed, lock_requests: requests }
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
	options = if (to.is_empty()) [] else [("to", to)]
	planned_given(locked, machine_settings, action, options)
}

# The plan of `kai machine ACTION web` given the command line's `options`, a
# flag's value "", in a locked project, for machine web's
# `machine_settings`.
planned_given :
	Locked, List(MachineSetting), Str, Options -> Try(Plan, Plan.Failure)
planned_given = |locked, machine_settings, action, options| {
	{ settings, nix_lock, system } = locked
	plugin = Machine.plugin(settings, [Machine("web", machine_settings)])
	args = [{ name: "action", value: Present(action) }]
		.append({ name: "machine", value: Many(["web"]) })
		.concat(options.map(|(name, value)| { name, value: Present(value) }))
	found = plugin.implementations
		.first()
		.map_err(|_| Plan.fail("no implementation"))?
	(found.fit)(args).map_err(Plan.fail)?
	requests = requests_of(settings, plugin)
	lock = published(settings, requests, nix_lock)
	host = { system: system }
	(found.plan)({ ..context, args, host, lock, lock_requests: requests })
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

# Machine web as it installs: with a Disk.
installed_web = web.append(Disk(SingleDisk("/dev/sda")))

# The plan of `kai machine install web --to TO` ("" for no --to) for machine
# web's `settings`, its disko locked.
installed : List(MachineSetting), Str -> Try(Plan, Plan.Failure)
installed = |settings, to| {
	system = "x86_64-linux"
	locked = { settings: project, nix_lock: disko_lock, system }
	planned_in(locked, settings, "install", to)
}

# An install expects nix and ssh, builds as `build` does, then builds the
# kexec installer of the locked nixpkgs into the workspace, confirms naming
# the target and the disk it erases, says what it is doing, then runs
# nixos-anywhere from the project's locked nixpkgs on the generated flake,
# read impurely as a build reads it, booting that installer, with its
# progress shown, recording the server's hardware facts in the project and
# saying so.
expect {
	target = "root@203.0.113.7"
	flake = "path:/generated/nix"
	facts = "/project/machines/web/facter.json"
	link = "/work/machines/web-installer"
	tarball = "${link}/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz"
	anywhere = ["--flake", "${flake}#web", "--target-host", target]
		.concat(["--option", "pure-eval", "false", "--kexec", tarball])
		.concat(["--generate-hardware-config", "nixos-facter", facts])
	toplevel = "nixosConfigurations.web.config.system.build.toplevel"
	match installed(installed_web, target) {
		Ok({ steps, next: Done }) =>
			match steps {
				[ExpectPrograms(tools), CheckSource(_), .. as rest] =>
					tools.programs == ["nix", "ssh"]
						and match rest.drop_first(1) {
							[Run(built), Run(installer), .. as after] =>
								built.argv.last() == Ok("${flake}#${toplevel}")
									and installer.argv.last()
										== Ok("${flake}#kexecInstallers.x86_64-linux")
									and installer.argv.contains(link)
									and match after {
										[Confirm(prompt), Note(saying), Run(ran), Note(wrote)] =>
											wrote
												== "wrote ${facts}, the machine's hardware facts; commit it"
												and prompt
													== "Install machine web on ${target}, ERASING its disk "
														.concat("/dev/sda and everything on it?")
												and saying
													== "installing machine web on ${target}: this erases "
														.concat("/dev/sda and takes several minutes")
												and ran.output == Inherit
												and match ran.argv {
													["sh", "-c", script, "sh", .. as given] =>
														given == [flake].concat(anywhere)
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
		_ => Bool.False
	}
}

# An install on a target with a port gives nixos-anywhere the host without
# it, and the port both before and after the installer boots.
expect {
	target = "root@[2001:db8::1]:2222"
	ran = match installed(installed_web, target) {
		Ok({ steps, .. }) => argvs(steps).last() ?? []
		Err(_) => []
	}
	expected = ["--flake", "path:/generated/nix#web"]
		.concat(["--target-host", "root@2001:db8::1"])
		.concat(["--ssh-port", "2222", "--post-kexec-ssh-port", "2222"])
	ran.drop_first(5).take_first(8) == expected
}

# A machine with a Disk adds nixos-images' noninteractive kexec installer
# for each system to the flake, which install builds; without one, the
# flake has none.
expect {
	mapped = "kexecInstallers = builtins.mapAttrs"
	installer = [
		mapped,
		"(system: packages:",
		"packages.kexec-installer-nixos-unstable-noninteractive)",
		"inputs.\"nixos-images\".packages;",
	]
	renders(installed_web, installer) and !renders(web, [mapped])
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
# with GRUB installed for BIOS and UEFI, and the hardware facts install
# records, once they exist. Without a Disk, none of them renders.
expect {
	facts = "/. + \"/project/machines/web/facter.json\""
	facter = [
		"hardware.facter.reportPath = let report = ${facts}; in",
		"if builtins.pathExists report then report else null;",
	]
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
	renders(installed_web, layout.concat(facter))
		and !renders(web, ["disko.devices.disk.main = {"])
		and !renders(web, ["efiSupport = true;"])
		and !renders(web, facter.take_first(1))
}

# A Disk is a /dev path of plain characters, given once; each is refused as
# Kaifile.roc compiles.
expect {
	disk = |device| Disk(SingleDisk(device))
	bad = |device|
		"machine web: Disk device ${device} is no /dev/... path, "
			.concat("such as \"/dev/sda\"")
	valid = ["/dev/sda", "/dev/nvme0n1", "/dev/disk/by-path/pci-0000:00:04.0"]
	invalid = ["sda", "/dev/", "/dev/../etc/passwd", "/dev/sd a", "/dev/x;y"]
	problems_of(installed_web) == []
		and valid.all(Machine.valid_device)
		and !invalid.any(Machine.valid_device)
		and problems_of(web.append(disk("/dev/sd\"a"))) == [bad("/dev/sd\"a")]
		and problems_of(web.concat([disk("/dev/sda"), disk("/dev/sdb")]))
			== ["machine web: Disk is given more than once"]
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

# Where switch, rollback and generations record the generations, and the
# script, sh -c SCRIPT sh PROFILE AS_ROOT..., each runs to activate or list,
# recording its stdout there.
generations = "/generated/machine/generations"

recording = |script, as_root|
	NixosBackend.recorded(
		generations,
		["sh", "-c", script, "sh", profile].concat(as_root),
	)

# Run steps' outputs, in order.
outputs : List(Plan.Step) -> List(Plan.Output)
outputs = |steps|
	steps.keep_oks(
		|step|
			match step {
				Run({ output, .. }) => Ok(output)
				_ => Err({})
			},
	)

# A switch checks the host first, builds as `build` does but leaves an
# out-link, confirms, says what it does, then quietly, as root, sets the
# system profile to it, activates it and waits for the host to settle,
# rolling back unless it comes up running, recording the generation it is.
# The whole plan is known up front, so --dry-run prints all of it.
expect {
	link = "/work/machines/web"
	guarded = recording(NixosBackend.guarded_switch, [link, "sudo"])
	plan = planned("switch", "x86_64-linux")
	observes = plan.map_ok(|p| p.next) == Ok(Observe([generations]))
	match plan.map_ok(|p| p.steps) {
		Ok([Run(check), _, _, Run(built), Confirm(prompt), Note(note), .. as rest]) =>
			observes
				and check.argv == NixosBackend.host_check("switch", web_machine)
				and built.argv.contains("--out-link")
				and built.argv.contains(link)
				and !built.argv.contains("--no-link")
				and prompt.starts_with("Switch this host to machine web,")
				and note
					== "activating machine web's system on this host, "
						.concat("which rolls back unless it comes up running")
				and argvs(rest) == [guarded]
				and outputs(rest) == [Quiet]
		_ => Bool.False
	}
}

# The guarded switch remembers the generation it ran before setting the
# profile, and on a failed activation or a host other than running lists
# the failed units and switches back to it, failing.
expect {
	script = NixosBackend.guarded_switch
	script.contains("systemctl is-system-running --wait")
		and script.contains("systemctl --failed")
		and script.contains("--switch-generation \"$generation\"")
		and script.ends_with("exit 1")
}

# With --no-rollback a switch sets the profile and activates it, keeping
# whatever comes up; only a switch takes it.
expect {
	activate = recording(NixosBackend.activation, ["sudo"])
	link = "/work/machines/web"
	set = ["sudo", "nix", "build", "--no-link", "--profile", profile, link]
	locked = { settings: project, nix_lock: flake_lock, system: "x86_64-linux" }
	without = |action| planned_given(locked, web, action, [("no-rollback", "")])
	switched = match without("switch").map_ok(|p| p.steps) {
		Ok([Run(_), _, _, Run(_), Confirm(_), Note(note), .. as rest]) =>
			note == "activating machine web's system on this host"
				and argvs(rest) == [set, activate]
				and outputs(rest) == [Quiet, Quiet]
		_ => Bool.False
	}
	refused = match without("rollback") {
		Err({ message, .. }) =>
			message == "--no-rollback is for kai machine switch alone"
		Ok(_) => Bool.False
	}
	switched and refused
}

# A rollback checks the host and confirms before rolling the profile back and
# activating it; generations only lists, with nothing to confirm or run as
# root. Each runs quietly and records the generations.
expect {
	activate = recording(NixosBackend.activation, ["sudo"])
	back = ["sudo", "nix", "profile", "rollback", "--profile", profile]
	observes = Observe([generations])
	rolled_back = match planned("rollback", "x86_64-linux") {
		Ok({ steps: [Run(check), Confirm(_), Note(_), .. as rest], next }) =>
			check.argv == NixosBackend.host_check("rollback", web_machine)
				and argvs(rest) == [back, activate]
				and outputs(rest) == [Quiet, Quiet]
				and next == observes
		_ => Bool.False
	}
	listed = match planned("generations", "x86_64-linux") {
		Ok({ steps: [Run(_), Run({ argv, output: Quiet, .. })], next }) =>
			argv == recording(NixosBackend.listing, []) and next == observes
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
					== "kai machine switch web without Host or --to acts on the host it "
						.concat("runs on; run it on www, or name its SSH target with ")
						.concat("Host or --to")
		_ => Bool.False
	}
	["switch", "rollback", "generations"].all(other) and checked
}

# Machine web living at an SSH target, and the remote nix command.
remote_web = web.append(Host("admin@web.example.com"))

remote_nix = ["nix", "--extra-experimental-features", "nix-command"]

# A remote switch's activation through `on_target`, which quotes for the
# remote shell, as root through `as_root`: started in a unit of its own and
# waited for over a new connection when the first drops, recording the
# generation.
detached : (List(Str) -> List(Str)), List(Str) -> List(Str)
detached = |on_target, as_root| {
	mode = |m|
		on_target(
			["sh", "-c", NixosBackend.detached_activation, "sh", m, profile]
				.concat(as_root),
		)
	NixosBackend.recorded(
		generations,
		NixosBackend.reconnecting(mode("start"), mode("wait")),
	)
}

# A remote switch expects nix and ssh, checks the target, builds here as a
# local switch does, confirms naming the target, then quietly copies the
# system there, arms the rollback timer, sets its profile to the store path,
# activates it in a unit of its own and stops the timer over a new
# connection, each connecting again should its connection drop, through
# sudo for a user other than root, recording the generation it is. A note
# says what each does.
expect {
	target = "admin@web.example.com"
	link = "/work/machines/web"
	copy = ["nix", "copy", "--no-check-sigs", "--substitute-on-destination"]
		.concat(["--to", "ssh-ng://${target}", link])
	profile_command = ["sudo"]
		.concat(remote_nix)
		.concat(["build", "--no-link", "--profile", profile])
	set = NixosBackend.remote_profile(link, target, profile_command, [])
	on_target = |argv|
		["ssh", target, "--"].concat(argv.map(NixosBackend.shell_quote))
	on_profile = |script| on_target(["sh", "-c", script, "sh", profile, "sudo"])
	arm = on_profile(NixosBackend.arming)
	activate = detached(on_target, ["sudo"])
	stop = on_target(["sudo", "systemctl", "stop", "kai-rollback.timer"])
	disarm = NixosBackend.reconnecting(stop, stop)
	machine = Machine.machine("web", remote_web)
	notes = [
		"copying machine web's system to ${target}",
		"activating it on ${target}, which rolls back unless kai reaches it again",
	]
	match planned_with(remote_web, "switch", "x86_64-linux", "") {
		Ok({ steps, next: Observe([observed]) }) =>
			match steps {
				[ExpectPrograms(tools), Run(check), _, _, Run(built), .. as rest] =>
					tools.programs == ["nix", "ssh"]
						and observed == generations
						and check.argv == NixosBackend.remote_check(machine, target, [])
						and built.argv.contains(link)
						and match rest {
							[Confirm(prompt), ..] =>
								prompt.starts_with("Switch ${target} to machine web,")
							_ => Bool.False
						}
						and argvs(rest) == [copy, arm, set, activate, disarm]
						and outputs(rest) == [Quiet, Quiet, Quiet, Quiet, Quiet]
						and rest.keep_oks(
							|step|
								match step {
									Note(note) => Ok(note)
									_ => Err({})
								},
						)
							== notes
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

# With --no-rollback a remote switch arms no timer: it sets the profile and
# activates it in a unit of its own, and stops nothing.
expect {
	target = "admin@web.example.com"
	link = "/work/machines/web"
	copy = ["nix", "copy", "--no-check-sigs", "--substitute-on-destination"]
		.concat(["--to", "ssh-ng://${target}", link])
	profile_command = ["sudo"]
		.concat(remote_nix)
		.concat(["build", "--no-link", "--profile", profile])
	set = NixosBackend.remote_profile(link, target, profile_command, [])
	on_target = |argv|
		["ssh", target, "--"].concat(argv.map(NixosBackend.shell_quote))
	locked = { settings: project, nix_lock: flake_lock, system: "x86_64-linux" }
	match planned_given(locked, remote_web, "switch", [("no-rollback", "")]) {
		Ok({ steps: [_, Run(_), _, _, Run(_), Confirm(_), .. as rest], .. }) =>
			argvs(rest) == [copy, set, detached(on_target, ["sudo"])]
				and said(rest).last() == Ok("activating it on ${target}")
		_ => Bool.False
	}
}

# --to overrides Host; as root, a remote rollback and listing run nothing
# through sudo. Rollback confirms first; generations only lists. Both run
# quietly and record the generations.
expect {
	target = "root@203.0.113.7"
	on_target = |argv| ["ssh", target, "--"].concat(argv)
	remote_recording = |script|
		NixosBackend.recorded(
			generations,
			on_target(
				["sh", "-c", script, "sh", profile].map(NixosBackend.shell_quote),
			),
		)
	back = on_target(
		remote_nix.concat(["profile", "rollback", "--profile", profile]),
	)
	activate = remote_recording(NixosBackend.activation)
	on = |action| planned_with(remote_web, action, "x86_64-linux", target)
	rolled_back = match on("rollback").map_ok(|plan| plan.steps) {
		Ok([ExpectPrograms(tools), Run(check), Confirm(prompt), .. as rest]) =>
			tools.programs == ["ssh"]
				and check.argv.get(4) == Ok(target)
				and prompt.starts_with("Switch ${target} back")
				and rest.first() == Ok(Note("activating the previous system on ${target}"))
				and argvs(rest) == [back, activate]
				and outputs(rest) == [Quiet, Quiet]
		_ => Bool.False
	}
	listed = match on("generations") {
		Ok({ steps: [ExpectPrograms(_), Run(_), Run({ argv, output, .. })], .. }) =>
			argv == remote_recording(NixosBackend.listing)
				and output == Quiet
		_ => Bool.False
	}
	rolled_back and listed
}

# A target's port reaches every SSH connection apart from its host: ssh's
# -p in the host check, the profile and the activation, and NIX_SSHOPTS for
# nix copy, whose store URL holds the host alone.
expect {
	target = "admin@[2001:db8::1]:2222"
	destination = "admin@2001:db8::1"
	port = ["-p", "2222"]
	link = "/work/machines/web"
	copy = ["nix", "copy", "--no-check-sigs", "--substitute-on-destination"]
		.concat(["--to", "ssh-ng://${destination}", link])
	on_target = |argv|
		["ssh", "-p", "2222", destination, "--"]
			.concat(argv.map(NixosBackend.shell_quote))
	activate = detached(on_target, ["sudo"])
	match planned_with(remote_web, "switch", "x86_64-linux", target) {
		Ok({ steps: [_, Run(check), .. as rest], .. }) => {
			ran = argvs(rest)
			(copied, set) = match ran.drop_first(ran.len() - 5) {
				[c, _, s, a, _] if a == activate => (c, s)
				_ => ([], [])
			}
			check.argv.get(4) == Ok(target)
				and check.argv.get(5) == Ok(destination)
				and check.argv.drop_first(9) == port
				and set.drop_first(5).first() == Ok(destination)
				and set.drop_first(7) == port
				and copied == NixosBackend.with_ssh_options(port, copy)
				and copied.get(4) == Ok("-p 2222")
		}
		_ => Bool.False
	}
}

# The plan of `kai machine ACTION web --to TO` continuing once its last step
# recorded `text` as the generations.
reported : Str, Str, Str -> Try(Plan, Plan.Failure)
reported = |action, to, text| {
	plugin = Machine.plugin(project, [Machine("web", remote_web)])
	args = [{ name: "action", value: Present(action) }]
		.append({ name: "machine", value: Many(["web"]) })
		.concat(if (to.is_empty()) [] else [{ name: "to", value: Present(to) }])
	observed = [{ path: generations, contents: Text(text) }]
	found = plugin.implementations
		.first()
		.map_err(|_| Plan.fail("no implementation"))?
	(found.plan)({ ..context, args, phase: 1, observed })
}

# Once it has run, a switch says which generation the machine now runs and
# where, a rollback which generation the host now runs, and generations
# prints one line each, oldest first, marking the current one, to the
# minute.
expect {
	listing =
		\\system-43-link
		\\system-9-link 2026-11-01 08:15:42.123456789 +0000
		\\system-43-link 2026-11-14 10:03:12.000000000 +0000
	target = "root@203.0.113.7"
	steps = |action, to, text| reported(action, to, text).map_ok(|p| p.steps)
	running = "is now running generation"
	steps("switch", "", "system-43-link\n")
		== Ok([Note("machine web ${running} 43 on admin@web.example.com")])
		and steps("rollback", target, "system-42-link\n")
			== Ok([Note("${target} ${running} 42")])
		and steps("generations", "", listing)
			== Ok([
				Print("generation 9  2026-11-01 08:15"),
				Print("generation 43  2026-11-14 10:03  (current)"),
			])
		and reported("switch", "", "").map_ok(|p| p.next) == Ok(Done)
}

# The remote check passes the target, the destination ssh connects to,
# architecture and messages as the script's arguments, and the profile step
# quotes its command for the remote shell while the store path stays an
# argument too.
expect {
	target = "admin@web.example.com"
	machine = Machine.machine("web", remote_web)
	checked = match NixosBackend.remote_check(machine, target, []) {
		["sh", "-c", script, "sh", given, destination, "x86_64", is, then] =>
			!script.contains(target)
				and given == target
				and destination == target
				and is == "machine web is x86_64-linux"
				and then == "run kai machine install web --to ${target} first"
		_ => Bool.False
	}
	command = ["a b", "it's", "c"]
	set = match NixosBackend.remote_profile("/work/x", target, command, []) {
		["sh", "-c", script, "sh", "/work/x", "admin@web.example.com", quoted] =>
			!script.contains(target) and quoted == "'a b' 'it'\\''s' c"
		_ => Bool.False
	}
	checked and set
}

# Machine web at its Host with Operators, so a remote action reads its host
# key first.
keyed_web = remote_web.append(Operators([operator]))

# Files a continuation read.
Observed : List({ path : Str, contents : [Missing, Text(Str)] })

# The plan of `kai machine ACTION web` for `settings` at `phase`, having
# read `observed`.
continued : List(MachineSetting), Str, U64, Observed -> Try(Plan, Plan.Failure)
continued = |settings, action, phase, observed| {
	plugin = Machine.plugin(project, [Machine("web", settings)])
	args = [{ name: "action", value: Present(action) }]
		.append({ name: "machine", value: Many(["web"]) })
	requests = requests_of(project, plugin)
	lock = published(project, requests, flake_lock)
	found = plugin.implementations
		.first()
		.map_err(|_| Plan.fail("no implementation"))?
	planning = { ..context, args, lock, lock_requests: requests, phase, observed }
	(found.plan)(planning)
}

# Where a remote action copies the host public key, and the known hosts file
# it writes from it.
host_key_copy = "/generated/machine/host-key.pub"

known_hosts = "/generated/machine/known_hosts"

# A remote action on a machine with Operators first copies its host public
# key, if any, into the generated files, quietly, and reads the copy back.
expect {
	match continued(keyed_web, "switch", 0, []) {
		Ok({ steps: [Run({ argv, output: Quiet, .. })], next }) =>
			next == Observe([host_key_copy])
				and argv.drop_first(3)
					== ["sh", "/project/secrets/hosts/web.pub", host_key_copy]
		_ => Bool.False
	}
}

# With the key, every SSH connection trusts it alone: a known hosts file
# holding it under the machine's name, written before the host check, and
# ssh options naming it, passed to ssh and, in NIX_SSHOPTS, to nix copy.
expect {
	target = "admin@web.example.com"
	pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5host root@web\n"
	options = ["-o", "UserKnownHostsFile=${known_hosts}"]
		.concat(["-o", "GlobalKnownHostsFile=/dev/null"])
		.concat(["-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=web"])
	written = { path: known_hosts, contents: "web ${pub}" }
	link = "/work/machines/web"
	copy = ["nix", "copy", "--no-check-sigs", "--substitute-on-destination"]
		.concat(["--to", "ssh-ng://${target}", link])
	profile_command = ["sudo"]
		.concat(remote_nix)
		.concat(["build", "--no-link", "--profile", profile])
	set = NixosBackend.remote_profile(link, target, profile_command, options)
	on_target = |argv|
		["ssh"]
			.concat(options)
			.concat([target, "--"])
			.concat(argv.map(NixosBackend.shell_quote))
	activation = ["sh", "-c", NixosBackend.activation, "sh", profile, "sudo"]
	activate = NixosBackend.recorded(generations, on_target(activation))
	arm = on_target(["sh", "-c", NixosBackend.arming, "sh", profile, "sudo"])
	stop = on_target(["sudo", "systemctl", "stop", "kai-rollback.timer"])
	disarm = NixosBackend.reconnecting(stop, stop)
	switching = detached(on_target, ["sudo"])
	rollback = ["profile", "rollback", "--profile", profile]
	back = on_target(["sudo"].concat(remote_nix).concat(rollback))
	observed = [{ path: host_key_copy, contents: Text(pub) }]
	on = |action| continued(keyed_web, action, 1, observed)
	machine = Machine.machine("web", keyed_web)
	copied = NixosBackend.with_ssh_options(options, copy)
	switched = match on("switch") {
		Ok({ steps: [_, Write([file]), Run(check), .. as rest], next }) =>
			file == written
				and next == Observe([generations])
				and check.argv == NixosBackend.remote_check(machine, target, options)
				and argvs(rest).drop_first(argvs(rest).len() - 5)
					== [copied, arm, set, switching, disarm]
		_ => Bool.False
	}
	nix_options = match copied {
		["sh", "-c", script, "sh", joined, .. as rest] =>
			rest == copy
				and script.contains("options=\"$options $NIX_SSHOPTS\"")
				and joined == Str.join_with(options, " ")
		_ => Bool.False
	}
	rolled_back = match on("rollback") {
		Ok({ steps: [_, Write([file]), Run(_), Confirm(_), _, .. as rest], .. }) =>
			file == written and argvs(rest) == [back, activate]
		_ => Bool.False
	}
	switched and nix_options and rolled_back
}

# With the key and a port, ssh and nix copy take the port before the trust;
# the known hosts file names the machine, not the address or port.
expect {
	keyed_port = web
		.append(Host("admin@web.example.com:2222"))
		.append(Operators([operator]))
	pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5host root@web\n"
	options = ["-p", "2222", "-o", "UserKnownHostsFile=${known_hosts}"]
		.concat(["-o", "GlobalKnownHostsFile=/dev/null"])
		.concat(["-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=web"])
	copy = ["nix", "copy", "--no-check-sigs", "--substitute-on-destination"]
		.concat(["--to", "ssh-ng://admin@web.example.com", "/work/machines/web"])
	observed = [{ path: host_key_copy, contents: Text(pub) }]
	match continued(keyed_port, "switch", 1, observed) {
		Ok({ steps: [_, Write([file]), Run(_), .. as rest], .. }) =>
			file == { path: known_hosts, contents: "web ${pub}" }
				and argvs(rest).contains(NixosBackend.with_ssh_options(options, copy))
		_ => Bool.False
	}
}

# Without the key, a machine with Operators connects as one without does,
# trusting the operator's known hosts, and reports a phase later; an empty
# key fails.
expect {
	missing = [{ path: host_key_copy, contents: Missing }]
	steps = |settings, phase, observed|
		continued(settings, "generations", phase, observed).map_ok(|p| p.steps)
	empty = [{ path: host_key_copy, contents: Text("\n") }]
	recorded = [{ path: generations, contents: Text("system-43-link\n") }]
	failure = continued(keyed_web, "generations", 1, empty).map_err(|f| f.message)
	steps(keyed_web, 1, missing) == steps(remote_web, 0, [])
		and steps(keyed_web, 2, recorded) == steps(remote_web, 1, recorded)
		and failure == Err("secrets/hosts/web.pub holds no public key")
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
# optional account name, then an optional port from 1 to 65535, an IPv6
# host in brackets before one; never an option, spaces or control
# characters. A bad Host is refused as Kaifile.roc compiles.
expect {
	parts = |target|
		MachineModel.parse_target(target)
			.map_ok(|{ user, host, port }| (user, host, port))
	parsed =
		parts("web") == Ok(("", "web", ""))
			and parts("root@203.0.113.7") == Ok(("root", "203.0.113.7", ""))
			and parts("web:2222") == Ok(("", "web", "2222"))
			and parts("admin@web.example.com:22")
				== Ok(("admin", "web.example.com", "22"))
			and parts("root@2001:db8::1") == Ok(("root", "2001:db8::1", ""))
			and parts("root@[2001:db8::1]") == Ok(("root", "2001:db8::1", ""))
			and parts("root@[2001:db8::1]:65535")
				== Ok(("root", "2001:db8::1", "65535"))
	invalid = [
		"",
		"-oProxyCommand=x",
		"admin@-web",
		"Admin@web",
		"@web",
		"admin@",
		"web:",
		"web:0",
		"web:65536",
		"web:+22",
		"web:2x",
		"-p:22",
		"[web]:22",
		"[2001:db8::1]2222",
		"[2001:db8::1]:",
		"web example",
		"web\n",
		"a@b@c",
	]
	required = [System("x86_64-linux"), StateVersion("25.05")]
	parsed
		and !invalid.any(MachineModel.valid_target)
		and problems_of(required.append(Host("web:0")))
			== ["machine web: Host web:0 is no SSH target; ${MachineModel.target_form}"]
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

# Machine web with a provider's profile from the locked input "profiles".
profiled_web =
	web.append(InputModules("profiles", ["digitalocean.nix", "do/net.nix"]))

# Modules of a locked input follow the project's, as paths inside the
# input's store path, which a pure evaluation reads; InputModules repeats.
expect
	renders(
		profiled_web.append(InputModules("extra", ["x.nix"])),
		[
			"(/. + \"/project/nixos/web.nix\")",
			"(inputs.\"profiles\" + \"/digitalocean.nix\")",
			"(inputs.\"profiles\" + \"/do/net.nix\")",
			"(inputs.\"extra\" + \"/x.nix\")",
			"];",
		],
	)

# A module of an input is a relative .nix path that stays inside it.
expect {
	paths = ["../web.nix", "/web.nix", "a//web.nix", "./web.nix", "web"]
	problems_of(web.append(InputModules("profiles", paths)))
		== paths.map(
			|path|
				"machine web: module ${path} is no .nix file inside input profiles",
		)
}

# The input InputModules names is one std's settings declare or a plugin
# asks std to lock; any other is refused as Kaifile.roc compiles.
expect {
	declared = project.append(Input("profiles", "github:org/kai-profiles"))
	reference = "github:org/kai-profiles"
	provider = Plugin.new({
		name: "digitalocean",
		version: "",
		describe: "",
		commands: [],
		backends: [],
		implementations: [],
	})
		.locking([Input("profiles", reference, [])])
	validated = |settings, others| {
		machine = Machine.plugin(settings, [Machine("web", profiled_web)])
		plugins = [Std.plugin(settings), machine].concat(others)
		Kaifile.validate(Kaifile.new(plugins)).map_ok(|_| {})
	}
	validated(declared, []) == Ok({})
		and validated(project, [provider]) == Ok({})
		and validated(project, [])
			== Err(
				"machine: machine web: InputModules names input profiles, "
					.concat("which neither std's settings declare nor a plugin ")
					.concat("locks; add Input(\"profiles\", ...) to them"),
			)
}

# The flake.lock nix flake update writes for the project's nixpkgs, disko,
# nixos-images and agenix, whose own nixpkgs follow the project's.
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
	\\      "inputs": { "nixpkgs": ["default"] },
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
	\\      "inputs": { "nixpkgs": ["default"] },
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
	\\    "nixos-images": {
	\\      "inputs": {
	\\        "nixos-stable": ["default"], "nixos-unstable": ["default"]
	\\      },
	\\      "locked": {
	\\        "lastModified": 1790100000,
	\\        "narHash": "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=",
	\\        "owner": "nix-community",
	\\        "repo": "nixos-images",
	\\        "rev": "fedcba9876543210fedcba9876543210fedcba98",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "nix-community", "repo": "nixos-images", "type": "github"
	\\      }
	\\    },
	\\    "root": {
	\\      "inputs": {
	\\        "default": "default", "disko": "disko", "agenix": "agenix",
	\\        "nixos-images": "nixos-images"
	\\      }
	\\    }
	\\  },
	\\  "root": "root",
	\\  "version": 7
	\\}

# The project with disko, nixos-images and agenix locked, as a machine with
# a Disk and Secrets asks, on an x86_64-linux host.
agenix_locked = {
	settings: project,
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
	given = if (identity.is_empty()) [] else [("identity", identity)]
	secret_planned_with(settings, action, words, given)
}

# Options, each a name and its value.
Options : List((Str, Str))

# The plan of `kai secret ACTION WORDS...` with `options` for machine web's
# `settings`.
secret_planned_with :
	List(MachineSetting), Str, List(Str), Options -> Try(Plan, Plan.Failure)
secret_planned_with = |settings, action, words, options| {
	plugin = Machine.plugin(project, [Machine("web", settings)])
	args = [{ name: "action", value: Present(action) }]
		.append({ name: "names", value: Many(words) })
		.concat(options.map(|(name, value)| { name, value: Present(value) }))
	found = plugin.implementations
		.find_first(|i| i.command == "secret")
		.map_err(|_| Plan.fail("no implementation"))?
	(found.fit)(args).map_err(Plan.fail)?
	requests = requests_of(project, plugin)
	lock = published(project, requests, agenix_lock)
	(found.plan)({ ..context, args, lock, lock_requests: requests })
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
											NixosBackend.without_host_key(web_machine),
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
# own temporary directory and places it with --extra-files, and boots the
# installer built just before. The target and every name and key are
# arguments.
expect {
	target = "root@203.0.113.7"
	flake = "path:/generated/nix"
	facts = "/project/machines/web/facter.json"
	tarball = "/work/machines/web-installer/"
		.concat("nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz")
	match planned_in(agenix_locked, secret_web, "install", target) {
		Ok({ steps, next: Done }) =>
			match argvs(steps).take_last(2) {
				[installer, argv] =>
					installer.last() == Ok("${flake}#kexecInstallers.x86_64-linux")
						and match argv.split_at(with_age.len()) {
							{ before, others: [script, "sh", .. as given] } =>
								before == with_age
									and given
										== [flake, "", "/project/secrets", "web", "${operator}\n${key}"]
											.concat(["--flake", "${flake}#web", "--target-host", target])
											.concat(["--option", "pure-eval", "false", "--kexec", tarball])
											.concat(["--generate-hardware-config", "nixos-facter", facts])
									and script.contains("--extra-files \"$files\"")
									and script.contains("ssh-keygen -q -t ed25519 -N ''")
									and script.contains("age -d -i \"$identity\" -o \"$key\"")
									and script.contains("default#nixos-anywhere")
									and !script.contains(target)
									and !script.contains("exec ")
							_ => Bool.False
						}
				_ => Bool.False
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
					["sh", "-c", script, "sh", "web", "", given] =>
						given == file
							and script.contains("set=\"kai secret set $name $secret$instance\"")
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
# owners, groups and modes, duplicates, and Secrets without Operators.
expect {
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
	accepted = installed_with([operators, secret("app.env_1-x", [Mode("640")])])
	checks.all(
		|(settings, expected)|
			problems_of(settings) == expected.map(|p| "machine web: ${p}"),
	)
		and problems_of(accepted) == []
}

# Caddy serving a proxied site and a directory, with an email.
caddy_web = web.append(
	Services([
		Caddy([
			Email("admin@example.com"),
			Site("example.com", ReverseProxy("localhost:8080")),
			Site("files.example.com", Files("/srv/files")),
		]),
	]),
)

# Caddy renders NixOS's services.caddy, with its email and one virtual host
# per site, and opens TCP 80 and 443 and UDP 443 beside Firewall's ports,
# each once.
expect {
	opened = |ports| "networking.firewall.allowedTCPPorts = [ ${ports} ];"
	virtual_host = |domain, caddyfile|
		"services.caddy.virtualHosts.\"${domain}\".extraConfig = \"${caddyfile}\";"
	site = Site("example.com", ReverseProxy("localhost:8080"))
	without_firewall = web
		.drop_if(|s| Machine.setting_name(s) == "Firewall")
		.append(Services([Caddy([site])]))
	other_ports = without_firewall.append(Firewall([Tcp([443, 8443])]))
	udp = |ports| "networking.firewall.allowedUDPPorts = [ ${ports} ];"
	quic = without_firewall.append(Firewall([Udp([443, 4433])]))
	renders(
		caddy_web,
		[
			opened("80 443"),
			udp("443"),
			"services.caddy.enable = true;",
			"services.caddy.email = \"admin@example.com\";",
			virtual_host("example.com", "reverse_proxy localhost:8080"),
			virtual_host("files.example.com", "root * /srv/files\\nfile_server"),
		],
	)
		and renders(without_firewall, [opened("80 443")])
		and renders(other_ports, [opened("443 8443 80")])
		and renders(quic, [udp("443 4433")])
		and !renders(web, ["networking.firewall.allowedUDPPorts = [ 443 ];"])
		and !renders(without_firewall, ["services.caddy.email = \"\";"])
		and !renders(web, ["services.caddy.enable = true;"])
}

# Services are checked as Kaifile.roc compiles: Caddy's own checks, and
# Services or Caddy given twice.
expect {
	site = Site("example.com", ReverseProxy("localhost:8080"))
	checks = [
		(caddy_web, []),
		(web.append(Services([Caddy([])])), ["Caddy needs at least one Site"]),
		(
			web.append(Services([Caddy([site]), Caddy([site])])),
			["Caddy is given more than once"],
		),
		(
			web.concat([Services([Caddy([site])]), Services([])]),
			["Services is given more than once"],
		),
		(
			web.append(Services([Caddy([site, site])])),
			["Caddy site example.com is declared more than once"],
		),
	]
	checks.all(
		|(settings, expected)|
			problems_of(settings) == expected.map(|p| "machine web: ${p}"),
	)
}

# The flake files std's update writes for `settings`, given every lock
# request of `plugins`, std's among them.
update_files : List(Config.Setting), List(Plugin) -> List(Str)
update_files = |settings, plugins| {
	requests = Kaifile.lock_requests(Kaifile.new(plugins))
	update = Std.plugin(settings).implementations
		.find_first(|i| i.command == "update" and i.backend == On("nix"))
	match update.map_ok(|i| (i.plan)({ ..context, lock_requests: requests })) {
		Ok(Ok(plan)) =>
			plan.steps.join_map(
				|step|
					match step {
						Write(files) => files.map(|f| f.contents)
						_ => []
					},
			)
		_ => []
	}
}

# Machines keep std's "default" source locked, as they are built from it,
# even when no environment uses it; without machines std leaves it out.
expect {
	bare = [Name("site"), Systems(["x86_64-linux"])]
	minimal = [System("x86_64-linux"), StateVersion("25.05")]
	machine = Machine.plugin(bare, [Machine("web", minimal)])
	locks_default = |plugins|
		update_files(bare, plugins).any(|text| text.contains("\"default\" = {"))
	machine.lock_requests == [Source("default")]
		and Machine.plugin(bare, []).lock_requests == []
		and Kaifile.validate(Kaifile.new([Std.plugin(bare), machine])).is_ok()
		and locks_default([Std.plugin(bare), machine])
		and !locks_default([Std.plugin(bare), Machine.plugin(bare, [])])
}

# A machine with a Disk asks std to lock disko and nixos-images, and one
# with Secrets agenix, each with its nixpkgs following the project's, as the
# flake `kai update` resolves declares. A project that declares disko alike
# is accepted; one declaring another disko is told to remove it.
expect {
	following = [Follows("nixpkgs", "default")]
	disko = Input("disko", "github:nix-community/disko", following)
	images = Input(
		"nixos-images",
		"github:nix-community/nixos-images",
		[Follows("nixos-unstable", "default"), Follows("nixos-stable", "default")],
	)
	agenix = Input("agenix", "github:ryantm/agenix", following)
	secrets = [Operators([operator]), Secrets([Secret("db", [])])]
	requested = |settings|
		Machine.plugin(project, [Machine("web", settings)]).lock_requests
	validated = |settings| {
		machine = Machine.plugin(settings, [Machine("web", installed_web)])
		Kaifile.validate(Kaifile.new([Std.plugin(settings), machine]))
			.map_ok(|_| {})
	}
	machine = Machine.plugin(project, [Machine("web", secret_web)])
	flake = update_files(project, [Std.plugin(project), machine])
	follows = |input, nixpkgs|
		flake.any(
			|text|
				text.contains("\"${input}\".inputs.\"${nixpkgs}\".follows = \"default\";"),
		)
	requested(web) == [Source("default")]
		and requested(installed_web) == [Source("default"), disko, images]
		and requested(web.concat(secrets)) == [Source("default"), agenix]
		and follows("disko", "nixpkgs")
		and follows("agenix", "nixpkgs")
		and follows("nixos-images", "nixos-unstable")
		and follows("nixos-images", "nixos-stable")
		and validated(project.append(Input("disko", "github:nix-community/disko")))
			== Ok({})
		and validated(project.append(Input("disko", "github:example/disko")))
			== Err(
				"std: machine asks to lock Input disko at github:nix-community/disko, "
					.concat("but the project declares github:example/disko; ")
					.concat("remove disko from std's settings to use machine's"),
			)
}

# Machine web at its Host, installed with Operators and a secret, beside
# machine db.
instance_web = secret_web.append(Host("admin@web.example.com"))

# The plan of `kai machine ACTION web` with `options` for machine web's
# `settings`, beside machine db, at `phase`, having read `observed`.
instanced : List(MachineSetting), Str, Options, U64, Observed -> Planned
instanced = |settings, action, options, phase, observed| {
	machines = [Machine("web", settings), Machine("db", web)]
	plugin = Machine.plugin(project, machines)
	args = [{ name: "action", value: Present(action) }]
		.append({ name: "machine", value: Many(["web"]) })
		.concat(options.map(|(name, value)| { name, value: Present(value) }))
	found = plugin.implementations
		.first()
		.map_err(|_| Plan.fail("no implementation"))?
	(found.fit)(args).map_err(Plan.fail)?
	requests = requests_of(project, plugin)
	lock = published(project, requests, agenix_lock)
	planning = { ..context, args, lock, lock_requests: requests, phase, observed }
	(found.plan)(planning)
}

Planned : Try(Plan, Plan.Failure)

# Steps' notes and prompts, in order.
said : List(Plan.Step) -> List(Str)
said = |steps|
	steps.keep_oks(
		|step|
			match step {
				Note(text) => Ok(text)
				Confirm(text) => Ok(text)
				_ => Err({})
			},
	)

# The contents of the files steps write.
written_text : List(Plan.Step) -> Str
written_text = |steps|
	steps
		.join_map(
			|step|
				match step {
					Write(files) => files.map(|file| file.contents)
					_ => []
				},
		)
		.fold("", Str.concat)

# `install web --as demo` keeps everything it records of the server under
# demo: the flake gains nixosConfigurations.demo, whose hostName is demo and
# which reads demo's hardware facts and secrets, beside web's own; the
# build, the installer's out-link, nixos-anywhere's flake attribute and the
# facts it records, the host key and the secrets it encrypts are demo's.
expect {
	target = "root@203.0.113.7"
	flake = "path:/generated/nix"
	toplevel = "nixosConfigurations.demo.config.system.build.toplevel"
	secret = "/project/secrets/demo/app-key.age"
	facts = "/project/machines/demo/facter.json"
	options = [("as", "demo"), ("to", target)]
	match instanced(instance_web, "install", options, 0, []) {
		Ok({ steps, next: Done }) => {
			ran = argvs(steps)
			anywhere = ran.last() ?? []
			given = anywhere.drop_first(with_age.len() + 2)
			flake_text = written_text(steps)
			checked = ["sh", "web", " --as demo", secret]
			ran.any(|argv| argv.last() == Ok("${flake}#${toplevel}"))
				and ran.any(|argv| argv.contains("/work/machines/demo-installer"))
				and ran.any(|argv| argv.drop_first(3) == checked)
				and steps.contains(CheckSource(secret))
				and given.take_first(4) == [flake, "", "/project/secrets", "demo"]
				and anywhere.contains("${flake}#demo")
				and anywhere.contains(facts)
				and flake_text.contains("\"web\" = inputs.\"default\".lib.nixosSystem")
				and flake_text.contains("\"demo\" = inputs.\"default\".lib.nixosSystem")
				and flake_text.contains("networking.hostName = \"demo\";")
				and flake_text.contains("(/. + \"${secret}\")")
				and flake_text.contains("/. + \"${facts}\"")
				and said(steps)
					== [
						"Install machine web as demo on ${target}, ERASING its disk "
							.concat("/dev/sda and everything on it?"),
						"installing machine web as demo on ${target}: this erases "
							.concat("/dev/sda and takes several minutes"),
						"wrote ${facts}, the machine's hardware facts; commit it",
					]
		}
		_ => Bool.False
	}
}

# HostName still names an instance's host.
expect {
	declared = Machine.machine("web", web.append(HostName("www")))
	www = { ..declared, instance: "demo" }
	rendered = NixosBackend.outputs([www], "/project")
	rendered.contains("\"demo\" = inputs.\"default\".lib.nixosSystem")
		and rendered.contains("networking.hostName = \"www\";")
}

# An instance never acts on Host, the machine's own server: without --to, a
# switch acts on this host, which must be named demo, and leaves its
# out-link under demo.
expect {
	why = "kai machine switch web --as demo without --to acts on the host it "
		.concat("runs on; run it on demo, or name its SSH target with --to")
	match instanced(instance_web, "switch", [("as", "demo")], 0, []) {
		Ok({ steps: [Run(check), .. as rest], .. }) =>
			match check.argv {
				["sh", "-c", _, "sh", "demo", given] =>
					given == why
						and argvs(rest).any(|argv| argv.contains("/work/machines/demo"))
						and said(rest).drop_first(1)
							== [
								"activating machine web as demo's system on this host, "
									.concat("which rolls back unless it comes up running"),
							]
				_ => Bool.False
			}
		_ => Bool.False
	}
}

# A remote action on an instance reads and trusts demo's host key, under
# demo's name, checks the target naming the install that makes demo, and
# says which instance runs which generation.
expect {
	target = "root@203.0.113.7"
	options = [("as", "demo"), ("to", target)]
	pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5host root@demo\n"
	at = |phase, observed|
		instanced(instance_web, "switch", options, phase, observed)
	read = match at(0, []) {
		Ok({ steps: [Run({ argv, .. })], .. }) =>
			argv.drop_first(3)
				== ["sh", "/project/secrets/hosts/demo.pub", host_key_copy]
		_ => Bool.False
	}
	switched = match at(1, [{ path: host_key_copy, contents: Text(pub) }]) {
		Ok({ steps: [_, Write([file]), Run(check), .. as rest], .. }) =>
			file == { path: known_hosts, contents: "demo ${pub}" }
				and check.argv.contains("HostKeyAlias=demo")
				and check.argv.contains("machine web as demo is x86_64-linux")
				and check.argv.contains(
					"run kai machine install web --as demo --to ${target} first",
				)
				and argvs(rest).any(|argv| argv.contains("/work/machines/demo"))
				and said(rest).contains(
					"copying machine web as demo's system to ${target}",
				)
		_ => Bool.False
	}
	recorded = [{ path: generations, contents: Text("system-43-link\n") }]
	running = "machine web as demo is now running generation 43 on ${target}"
	reports = at(2, recorded).map_ok(|plan| plan.steps) == Ok([Note(running)])
	read and switched and reports
}

# --as names an instance as a machine name that is also a host name, and
# never another machine; --as web is web itself.
expect {
	refused = |instance|
		match instanced(instance_web, "generations", [("as", instance)], 0, []) {
			Err({ message, .. }) => message
			Ok(_) => ""
		}
	no_instance = |instance|
		"--as ${instance} is no instance name; use a letter, then up to 62 "
			.concat("letters, digits, - or _, ending in a letter or digit")
	plain = instanced(instance_web, "generations", [], 0, [])
	refused("1x") == no_instance("1x")
		and refused("web-") == no_instance("web-")
		and refused("db") == "--as db names another machine; name another instance"
		and instanced(instance_web, "generations", [("as", "web")], 0, []) == plain
}

# `kai secret set web app-key --as demo` encrypts to demo's host key as
# secrets/demo/app-key.age, and rekey --as demo rekeys demo's secrets; both
# name the commands for demo when its host key is missing.
expect {
	demo = { ..Machine.machine("web", secret_web), instance: "demo" }
	unknown_host = NixosBackend.without_host_key(demo)
	given = |action, words|
		match secret_planned_with(secret_web, action, words, [("as", "demo")]) {
			Ok({ steps, .. }) =>
				argvs(steps).first().map_ok(|argv| argv.drop_first(with_age.len() + 2))
					?? []
			Err(_) => []
		}
	set = ["/project/secrets", "demo", "app-key", "${operator}\n${key}"]
	given("set", ["web", "app-key"]) == set.append(unknown_host)
		and given("rekey", ["web"]).take_first(3) == ["", "/project/secrets", "demo"]
		and unknown_host.starts_with("kai machine install web --as demo makes")
		and unknown_host.ends_with("run kai secret rekey web --as demo")
}
