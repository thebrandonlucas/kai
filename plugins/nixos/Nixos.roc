# The nixos plugin: `Machine(name, [...])` settings beside std's, each a
# NixOS system from a small typed core plus plain NixOS module files, and
# `kai machine build NAME`, which builds its toplevel from std's flake.
import pf.Command
import pf.Implementation
import pf.Plan
import pf.Plugin
import std.Config
import std.EnvName
import std.Std
import std.StdModel exposing [Model]
import std.System
import NixosBackend

Nixos := [].{

	## A NixOS machine, rendered as `nixosConfigurations.<name>` in std's
	## generated flake from its "default" package source.
	Setting : [Machine(Str, List(MachineSetting))]

	## System and StateVersion are required, and every setting but User
	## occurs at most once. HostName defaults to the machine's name. Ssh runs
	## OpenSSH with key logins only, root's only when root has keys. Firewall
	## opens ports beside OpenSSH's. Use puts a std environment's tools on
	## the system's PATH. Modules are NixOS module files relative to the
	## project, which receive the flake's `inputs`.
	MachineSetting : [
		System(System),
		HostName(Str),
		User(Str, List(UserSetting)),
		Ssh,
		Firewall(List(FirewallSetting)),
		Use(EnvName),
		TimeZone(Str),
		StateVersion(Str),
		Modules(List(Str)),
	]

	## A user's authorized SSH public keys and supplementary groups. Every
	## user but root is an ordinary user.
	UserSetting : [SshKeys(List(Str)), Groups(List(Str))]

	## Ports the firewall opens.
	FirewallSetting : [Tcp(List(U16)), Udp(List(U16))]

	Machine : NixosBackend.Machine

	## `project` is std's settings, whose environments and inputs machines
	## use; a machine's System must be one of its Systems.
	plugin : List(Config.Setting), List(Setting) -> Plugin
	plugin = |project, settings|
		match Nixos.checked(project, settings) {
			Ok(machines) =>
				Plugin.new({
					name: "nixos",
					version: "",
					describe: "",
					commands: [Nixos.command(machines)],
					backends: [],
					implementations: [Nixos.implementation(project, machines)],
				})
			Err(problems) => Plugin.invalid("nixos", problems)
		}

	command : List(Machine) -> Command
	command = |machines|
		Command.{
			name: "machine",
			summary: Nixos.page.description,
			help: Nixos.page,
			args: [
				Name({
					name: "action",
					help: "What to do with the machine.",
					choices: [
						{
							value: "build",
							summary: "Build the machine's system and print its store path.",
							details: [],
						},
					],
					default: Required,
				}),
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
		description: "Build a NixOS machine the project declares.",
		examples: ["kai machine build web", "kai --dry-run machine build web"],
		config: [
			"Machine(\"web\", [System(\"x86_64-linux\"), StateVersion(\"25.05\"),",
			"  User(\"admin\", [SshKeys([\"ssh-ed25519 AAAA...\"])]), Ssh,",
			"  Modules([\"nixos/web.nix\"])]),",
		],
	}

	implementation : List(Config.Setting), List(Machine) -> Implementation
	implementation = |project, machines|
		Implementation.{
			command: "machine",
			backend: On("nix"),
			fit: |args| Nixos.requested(machines, args).map_ok(|_| {}),
			plan: |ctx| {
				machine = Nixos.requested(machines, ctx.args).map_err(Plan.fail)?
				root = ctx.layout.project_root
				attribute = "nixosConfigurations.${machine.name}"
					.concat(".config.system.build.toplevel")
				built = Std.build_flake_output(
					project,
					ctx,
					{
						outputs: NixosBackend.outputs(machines, root),
						environments: machines
							.keep_if(|m| !m.environment.is_empty())
							.map(|m| m.environment),
						attribute,
						name: machine.name,
						description: "machine build ${machine.name}",
					},
				)?
				checks = machine.modules.map(|path| CheckSource("${root}/${path}"))
				Ok(Plan.{ steps: checks.concat(built.steps), next: built.next })
			},
		}

	## The machine `kai machine build NAME` names.
	requested : List(Machine), Command.Args -> Try(Machine, Str)
	requested = |machines, args| {
		name = match Command.trailing(args, "machine") {
			[one] => one
			_ => return Err(Nixos.name_one)
		}
		machines
			.find_first(|m| m.name == name)
			.map_err(|_| "unknown machine: ${name}")
	}

	name_one = "name one machine: kai machine build NAME"

	## The machines, or every problem with the settings.
	checked : List(Config.Setting), List(Setting) -> Try(List(Machine), List(Str))
	checked = |project, settings| {
		model = StdModel.from_settings(project).map_err(|why| [why])?
		var $machines = []
		var $problems = []
		for setting in settings {
			(name, parts) = match setting {
				Machine(machine_name, machine_settings) => (machine_name, machine_settings)
			}
			m = Nixos.machine(name, parts)
			given = parts
				.map(Nixos.setting_name)
				.drop_if(|s| s == "User")
			found = Nixos.repeated(given)
				.map(|s| "${s} is given more than once")
				.concat(Nixos.problems(model, m))
			$problems = $problems.concat(found.map(|p| "machine ${name}: ${p}"))
			$machines = $machines.append(m)
		}
		duplicated = Nixos.repeated($machines.map(|m| m.name))
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
			User(_, _) => "User"
			Ssh => "Ssh"
			Firewall(_) => "Firewall"
			Use(_) => "Use"
			TimeZone(_) => "TimeZone"
			StateVersion(_) => "StateVersion"
			Modules(_) => "Modules"
		}

	## A machine's settings folded into its fields; a later one wins, and
	## `checked` reports it.
	machine : Str, List(MachineSetting) -> Machine
	machine = |name, parts|
		parts.fold(
			{
				name,
				system: "",
				host_name: name,
				users: [],
				ssh: Bool.False,
				tcp_ports: [],
				udp_ports: [],
				environment: "",
				time_zone: "",
				state_version: "",
				modules: [],
			},
			|m, part|
				match part {
					System(system) => { ..m, system: system.to_str() }
					HostName(host_name) => { ..m, host_name }
					User(user, user_settings) => {
						..m,
						users: m.users.append(Nixos.user(user, user_settings)),
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
					Modules(modules) => { ..m, modules }
				},
		)

	user : Str, List(UserSetting) -> NixosBackend.User
	user = |name, settings|
		settings.fold(
			{ name, keys: [], groups: [] },
			|u, setting|
				match setting {
					SshKeys(keys) => { ..u, keys: u.keys.concat(keys) }
					Groups(groups) => { ..u, groups: u.groups.concat(groups) }
				},
		)

	## What is wrong with machine `m`, checked as Kaifile.roc compiles.
	problems : Model, Machine -> List(Str)
	problems = |model, m| {
		var $found = []
		if !Nixos.valid_machine_name(m.name) {
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
		if !Nixos.valid_state_version(m.state_version) {
			$found = $found.append(
				"StateVersion is required, as a release such as \"25.05\"",
			)
		}
		if !Nixos.valid_host_name(m.host_name) {
			$found = $found.append(
				"HostName ${m.host_name} is no host name; "
					.concat("use letters, digits, - or _"),
			)
		}
		if !Nixos.valid_time_zone(m.time_zone) {
			$found = $found.append(
				"TimeZone ${m.time_zone} is no time zone, such as \"Etc/UTC\"",
			)
		}
		for name in Nixos.repeated(m.users.map(|u| u.name)) {
			$found = $found.append("user ${name} is declared more than once")
		}
		for u in m.users {
			if !Nixos.valid_account(u.name) {
				$found = $found.append("user ${u.name} is no user name")
			}
			if u.name == "root" and !u.groups.is_empty() {
				$found = $found.append("root takes no Groups")
			}
			for group in u.groups.drop_if(Nixos.valid_account) {
				$found = $found.append("user ${u.name}: ${group} is no group name")
			}
			for key in u.keys.drop_if(Nixos.valid_ssh_key) {
				$found = $found.append(
					"user ${u.name}: \"${key}\" is no SSH public key",
				)
			}
		}
		if m.ssh and !m.users.any(|u| !u.keys.is_empty()) {
			# Only keys log in.
			$found = $found.append("Ssh needs a User with SshKeys")
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
		for path in m.modules.drop_if(Nixos.valid_module_path) {
			$found = $found.append(
				"module ${path} is no .nix file inside the project",
			)
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
				Nixos.letter(first)
					and rest.all(
						|b| Nixos.letter(b) or Nixos.digit(b) or b == '-' or b == '_',
					)
			[] => Bool.False
		}

	## NixOS's networking.hostName: up to 63 letters, digits, - or _,
	## starting and ending with a letter or digit.
	valid_host_name : Str -> Bool
	valid_host_name = |name| {
		bytes = name.to_utf8()
		alphanumeric = |b| Nixos.letter(b) or Nixos.digit(b)
		ends = match (bytes.first(), bytes.last()) {
			(Ok(first), Ok(last)) => alphanumeric(first) and alphanumeric(last)
			_ => Bool.False
		}
		ends
			and bytes.len() <= 63
			and bytes.all(|b| alphanumeric(b) or b == '-' or b == '_')
	}

	## Empty, for NixOS's default, or a zone name such as "Europe/Berlin".
	valid_time_zone : Str -> Bool
	valid_time_zone = |zone|
		zone.to_utf8().all(
			|b| Nixos.letter(b) or Nixos.digit(b) or "/_+-".to_utf8().contains(b),
		)

	## A user or group name: a-z or _, then at most 31 of a-z, 0-9, _ or -.
	valid_account : Str -> Bool
	valid_account = |name| {
		lower = |b| b >= 'a' and b <= 'z'
		match name.to_utf8() {
			[first, .. as rest] =>
				(lower(first) or first == '_')
					and rest.len() < 32
					and rest.all(|b| lower(b) or Nixos.digit(b) or b == '_' or b == '-')
			[] => Bool.False
		}
	}

	## A NixOS release such as "25.05".
	valid_state_version : Str -> Bool
	valid_state_version = |version| {
		two_digits = |part|
			part.count_utf8_bytes() == 2 and part.to_utf8().all(Nixos.digit)
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
			Nixos.letter(b) or Nixos.digit(b) or b == '+' or b == '/' or b == '='
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

	## A relative path to a .nix file that stays inside the project.
	valid_module_path : Str -> Bool
	valid_module_path = |path|
		path.ends_with(".nix")
			and path.split_on("/").all(|s| !s.is_empty() and s != "." and s != "..")
}

import pf.Layout

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

# The lock std's update publishes for `settings` from flake_lock.
published : List(Config.Setting) -> [Absent, Present(Str)]
published = |settings| {
	observed = [{ path: "/generated/nix/flake.lock", contents: Text(flake_lock) }]
	resumed = { ..context, phase: 1, observed }
	update = Std.plugin(settings).implementations
		.find_first(|i| i.command == "update" and i.backend == On("nix"))
	match update.map_ok(|i| (i.plan)(resumed)) {
		Ok(Ok({ steps: [PublishLock({ contents, .. }), ..], .. })) =>
			Present(contents)
		_ => Absent
	}
}

# The plan of `kai machine build NAME`, after the implementation fits.
build : List(Setting), Str -> Try(Plan, Plan.Failure)
build = |settings, name| {
	plugin = Nixos.plugin(project, settings)
	args = [{ name: "action", value: Present("build") }]
		.append({ name: "machine", value: Many([name]) })
	found = plugin.implementations
		.first()
		.map_err(|_| Plan.fail("no implementation"))?
	(found.fit)(args).map_err(Plan.fail)?
	(found.plan)({ ..context, args, lock: published(project) })
}

# Whether machine web's rendered lines, trimmed, hold `expected` in order.
renders : List(MachineSetting), List(Str) -> Bool
renders = |settings, expected| {
	rendered = NixosBackend.outputs([Nixos.machine("web", settings)], "/project")
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
	Nixos.plugin(project, [Machine("web", settings)]).problems

# A build checks the machine's modules, writes std's flake with the machine
# in nixosConfigurations, and builds its toplevel, printing the store path.
expect {
	toplevel = "nixosConfigurations.web.config.system.build.toplevel"
	outputs = NixosBackend.outputs([Nixos.machine("web", web)], "/project")
	match build([Machine("web", web)], "web").map_ok(|plan| plan.steps) {
		Ok([CheckSource(checked), Write([flake, ..]), Run({ argv, output, .. })]) =>
			checked == "/project/nixos/web.nix"
				and flake.contents.contains(outputs)
				and argv.last() == Ok("path:/generated/nix#${toplevel}")
				and output == Artifact({ name: "web", label: toplevel, output: "out" })
		_ => Bool.False
	}
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
	machines = [Nixos.machine("web", web)]
	db = [{ name: "machine", value: Many(["db"]) }]
	Nixos.requested(machines, db) == Err("unknown machine: db")
		and Nixos.requested(machines, []) == Err(Nixos.name_one)
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
	twice = Nixos.plugin(project, [Machine("web", web), Machine("web", web)])
	checks.all(
		|(settings, expected)|
			problems_of(settings) == expected.map(|p| "machine web: ${p}"),
	)
		and twice.problems == ["machine web is declared more than once"]
}
