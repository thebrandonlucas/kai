# The machine command on the nix backend: each machine is a NixOS system in
# std's generated flake, built from it, and switched to on this host.
import pf.Command
import pf.Implementation
import pf.Plan
import std.Config
import std.Std
import MachineModel exposing [Machine]

## Each machine is `lib.nixosSystem` of the "default" package source, with
## one module holding its typed settings, then its own module files by
## absolute path. Modules receive the flake's `inputs` as an argument.
NixosBackend :: [].{

	Project : List(Config.Setting)

	Planned : Try(Plan, Plan.Failure)

	Context : Implementation.Context

	implementation : Project, List(Machine) -> Implementation
	implementation = |project, machines|
		Implementation.{
			command: "machine",
			backend: On("nix"),
			fit: |args| MachineModel.requested(machines, args).map_ok(|_| {}),
			plan: |ctx| {
				m = MachineModel.requested(machines, ctx.args).map_err(Plan.fail)?
				action = Command.name(ctx.args, "action")
				if action == "build" {
					NixosBackend.build(project, machines, m, ctx, "")
				} else {
					NixosBackend.on_host(project, machines, m, ctx, action)
				}
			},
		}

	## What only Nix can honour that is wrong with machine `m`.
	problems : Machine -> List(Str)
	problems = |m|
		m.modules
			.drop_if(NixosBackend.valid_module_path)
			.map(|path| "module ${path} is no .nix file inside the project")

	## A relative path to a .nix file that stays inside the project.
	valid_module_path : Str -> Bool
	valid_module_path = |path|
		path.ends_with(".nix")
			and path.split_on("/").all(|s| !s.is_empty() and s != "." and s != "..")

	## NixOS's system profile, whose generations are the host's systems.
	profile = "/nix/var/nix/profiles/system"

	## Switching, rolling back and listing act on this host, which must be
	## the machine: its System now, its HostName as the plan runs. Only the
	## profile and the activation run as root.
	on_host : Project, List(Machine), Machine, Context, Str -> Planned
	on_host = |project, machines, m, ctx, action| {
		if ctx.host.system != m.system {
			return Err(
				Plan.fail(
					"machine ${m.name} is ${m.system}, but this host is ${ctx.host.system}: "
						.concat(NixosBackend.local_only(action, m)),
				),
			)
		}
		description = "machine ${action} ${m.name}"
		system_profile = NixosBackend.profile
		check = NixosBackend.host_check(action, m)
		here = NixosBackend.run("${description}: host check", Quiet, check)
		sudo = |argv| NixosBackend.run(description, Inherit, ["sudo"].concat(argv))
		activate = sudo(["${system_profile}/bin/switch-to-configuration", "switch"])
		restarting = "restarting changed services and booting it by default?"
		steps = match action {
			"switch" => {
				link = "${ctx.layout.workspace}/machines/${m.name}"
				built = NixosBackend.build(project, machines, m, ctx, link)?
				prompt = "Switch this host to machine ${m.name}, ${restarting}"
				set = sudo(["nix", "build", "--no-link", "--profile", system_profile, link])
				[here].concat(built.steps).concat([Confirm(prompt), set, activate])
			}
			"rollback" => {
				prompt = "Switch this host back to its previous system, ${restarting}"
				# Steps the profile's link back a generation, as `nix-env
				# --rollback` does: it needs no `nix profile` manifest.
				back = sudo(["nix", "profile", "rollback", "--profile", system_profile])
				[here, Confirm(prompt), back, activate]
			}
			_ => {
				listed = ["nixos-rebuild", "list-generations"]
				[here, NixosBackend.run(description, Inherit, listed)]
			}
		}
		Ok(Plan.{ steps, next: Done })
	}

	## `kai machine build`'s plan, leaving `out_link` ("" for none).
	build : Project, List(Machine), Machine, Context, Str -> Planned
	build = |project, machines, machine, ctx, out_link| {
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
				out_link,
			},
		)?
		checks = machine.modules.map(|path| CheckSource("${root}/${path}"))
		Ok(Plan.{ steps: checks.concat(built.steps), next: built.next })
	}

	## Why `action` refuses another host than `m`.
	local_only : Str, Machine -> Str
	local_only = |action, m|
		"kai machine ${action} acts on the host it runs on; run it on "
			.concat("${m.host_name}, or use kai deploy for another host")

	## A shell check, as the switch runs, that this host's name is the
	## machine's HostName. The names and the message are arguments, never
	## part of the script.
	host_check : Str, Machine -> List(Str)
	host_check = |action, m| {
		script =
			\\host=$(uname -n)
			\\[ "$host" = "$1" ] && exit 0
			\\echo "this host is $host, not $1: $2" >&2
			\\exit 1
		["sh", "-c", script, "sh", m.host_name, NixosBackend.local_only(action, m)]
	}

	run : Str, Plan.Output, List(Str) -> Plan.Step
	run = |description, output, argv|
		Run({
			description,
			argv,
			output,
			secrets: [],
			removed_environment_variables: [],
			kept_environment_variables: [],
		})

	## The flake outputs defining every machine, with module paths beneath
	## `project_root`; "" when there are none.
	outputs : List(Machine), Str -> Str
	outputs = |machines, project_root|
		if machines.is_empty() {
			""
		} else {
			defined = machines.map(|m| NixosBackend.machine(m, project_root))
			"      nixosConfigurations = {\n"
				.concat(Str.join_with(defined, ""))
				.concat("      };\n")
		}

	machine : Machine, Str -> Str
	machine = |m, project_root| {
		file = |path| "(/. + ${NixosBackend.quote("${project_root}/${path}")})"
		NixosBackend.lines(
			[
				"        ${NixosBackend.quote(m.name)} = "
					.concat("inputs.\"default\".lib.nixosSystem {"),
				"          specialArgs = { inherit inputs; };",
				"          modules = [",
				"            {",
			]
				.concat(NixosBackend.settings(m).map(|line| "              ${line}"))
				.append("            }")
				.concat(m.modules.map(|path| "            ${file(path)}"))
				.concat(["          ];", "        };"]),
		)
	}

	## The typed settings as NixOS option definitions.
	settings : Machine -> List(Str)
	settings = |m| {
		quote = NixosBackend.quote
		strings = |items| NixosBackend.list(items.map(quote))
		ports = |items| NixosBackend.list(items.map(U16.to_str))
		users = m.users.join_map(
			|u| {
				keys = "openssh.authorizedKeys.keys = ${strings(u.keys)};"
				if u.name == "root" {
					["users.users.root.${keys}"]
				} else {
					[
						"users.users.${quote(u.name)} = {",
						"  isNormalUser = true;",
						"  extraGroups = ${strings(u.groups)};",
						"  ${keys}",
						"};",
					]
				}
			},
		)
		# Only keys log in, root's only when it has some.
		root_keys = m.users.keep_if(|u| u.name == "root").join_map(|u| u.keys)
		root_login = if (root_keys.is_empty()) "no" else "prohibit-password"
		ssh = [
			"services.openssh = {",
			"  enable = true;",
			"  settings.PasswordAuthentication = false;",
			"  settings.KbdInteractiveAuthentication = false;",
			"  settings.PermitRootLogin = ${quote(root_login)};",
			"};",
		]
		firewall = |protocol, list|
			"networking.firewall.allowed${protocol}Ports = ${ports(list)};"
		# mkShell puts an environment's packages in nativeBuildInputs.
		shell = "(environmentsFor ${quote(m.system)}).${quote(m.environment)} { }"
		system_packages = [
			"environment.systemPackages =",
			"  (${shell}).nativeBuildInputs;",
		]
		when = |present, lines| if (present) lines else []
		[
			"nixpkgs.hostPlatform = ${quote(m.system)};",
			"networking.hostName = ${quote(m.host_name)};",
			"system.stateVersion = ${quote(m.state_version)};",
		]
			.concat(
				when(
					!m.time_zone.is_empty(),
					["time.timeZone = ${quote(m.time_zone)};"],
				),
			)
			.concat(users)
			.concat(when(m.ssh, ssh))
			.concat(when(!m.tcp_ports.is_empty(), [firewall("TCP", m.tcp_ports)]))
			.concat(when(!m.udp_ports.is_empty(), [firewall("UDP", m.udp_ports)]))
			.concat(when(!m.environment.is_empty(), system_packages))
	}

	list : List(Str) -> Str
	list = |items|
		if (items.is_empty()) "[ ]" else "[ ${Str.join_with(items, " ")} ]"

	lines : List(Str) -> Str
	lines = |items| items.fold("", |text, line| text.concat(line).concat("\n"))

	## A Nix string holding exactly `value`: interpolation cannot inject an
	## expression.
	quote : Str -> Str
	quote = |value| {
		escaped = value
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("\${", "\\\${")
			.replace_each("\n", "\\n")
			.replace_each("\r", "\\r")
			.replace_each("\t", "\\t")
		"\"${escaped}\""
	}
}
