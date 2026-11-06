# Nix rendering for NixOS machines: the nixosConfigurations output a machine
# build adds to std's generated flake.

## Each machine is `lib.nixosSystem` of the "default" package source, with
## one module holding its typed settings, then its own module files by
## absolute path. Modules receive the flake's `inputs` as an argument.
NixosBackend :: [].{

	Machine : {
		name : Str,
		system : Str,
		host_name : Str,
		users : List(User),
		ssh : Bool,
		tcp_ports : List(U16),
		udp_ports : List(U16),
		environment : Str,
		time_zone : Str,
		state_version : Str,
		modules : List(Str),
	}

	User : { name : Str, keys : List(Str), groups : List(Str) }

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
