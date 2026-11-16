# The machines a Kaifile declares, as every backend's implementation of the
# machine command reads them.
import pf.Command
import pf.Plan
import services.Caddy

MachineModel :: [].{

	## A machine's settings, folded. Modules and InputModules are Nix's
	## alone: the nix implementation checks them, and another backend would
	## refuse them. `input_modules` are module files inside locked inputs.
	## `instance` names the server it is installed on, by default its `name`:
	## what kai records of that server is kept under it. `host_name` is
	## HostName, "" for the instance's name. `host` is the SSH target it
	## lives at, "" for the host kai runs on. `disk` is
	## the layout install partitions and the system mounts. `operators` are
	## the public keys its host key and secrets are encrypted to,
	## `secrets` what it decrypts as it activates, and `services` what it
	## runs.
	Machine : {
		name : Str,
		instance : Str,
		system : Str,
		host_name : Str,
		host : Str,
		users : List(User),
		ssh : Bool,
		tcp_ports : List(U16),
		udp_ports : List(U16),
		environment : Str,
		time_zone : Str,
		state_version : Str,
		disk : Disk,
		operators : List(Str),
		secrets : List(Secret),
		services : List(Service),
		modules : List(Str),
		input_modules : List({ input : Str, path : Str }),
	}

	## A typed service, as its module in the services package folds it.
	Service : [Caddy(Caddy.Server)]

	## The TCP ports machine `m`'s firewall opens: Firewall's, then each
	## service's that Firewall does not already open.
	open_tcp_ports : Machine -> List(U16)
	open_tcp_ports = |m| {
		served = m.services.join_map(|Caddy(_)| Caddy.tcp_ports)
		MachineModel.adding(m.tcp_ports, served)
	}

	## The UDP ports machine `m`'s firewall opens, as `open_tcp_ports`.
	open_udp_ports : Machine -> List(U16)
	open_udp_ports = |m| {
		served = m.services.join_map(|Caddy(_)| Caddy.udp_ports)
		MachineModel.adding(m.udp_ports, served)
	}

	## `ports`, then each of `added` they do not already hold.
	adding : List(U16), List(U16) -> List(U16)
	adding = |ports, added|
		added.fold(
			ports,
			|all, port| if (all.contains(port)) all else all.append(port),
		)

	## A secret's name, and its file's owner, group and octal mode.
	Secret : { name : Str, owner : Str, group : Str, mode : Str }

	## No disk layout, or the whole disk at a device path.
	Disk : [NoDisk, SingleDisk(Str)]

	User : { name : Str, keys : List(Str), groups : List(Str) }

	## The machine `kai machine ACTION NAME` names, as the instance `--as`
	## names.
	requested : List(Machine), Command.Args -> Try(Machine, Str)
	requested = |machines, args| {
		name = match Command.trailing(args, "machine") {
			[one] => one
			_ => return Err(MachineModel.name_one)
		}
		m = machines
			.find_first(|found| found.name == name)
			.map_err(|_| "unknown machine: ${name}")?
		MachineModel.instance_of(machines, m, args)
	}

	## Machine `m` as the instance `--as` names, or as itself. An instance's
	## name is a machine name that is also a host name, and no other
	## machine's, whose files and system it would share.
	instance_of : List(Machine), Machine, Command.Args -> Try(Machine, Str)
	instance_of = |machines, m, args| {
		another_machine = |name| name != m.name and machines.any(|o| o.name == name)
		match Command.value(args, "as") {
			Err(NoValue) => Ok(m)
			Ok(instance) if !MachineModel.valid_instance(instance) =>
				Err(
					"--as ${instance} is no instance name; use a letter, then up to "
						.concat("62 letters, digits, - or _, ending in a letter or digit"),
				)
			Ok(instance) if another_machine(instance) =>
				Err("--as ${instance} names another machine; name another instance")
			Ok(instance) => Ok({ ..m, instance })
		}
	}

	## A letter, then up to 62 letters, digits, `-` or `_`, ending in a
	## letter or digit: a machine name that is also a host name.
	valid_instance : Str -> Bool
	valid_instance = |name| {
		letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')
		alphanumeric = |b| letter(b) or (b >= '0' and b <= '9')
		bytes = name.to_utf8()
		ends = match (bytes.first(), bytes.last()) {
			(Ok(first), Ok(last)) => letter(first) and alphanumeric(last)
			_ => Bool.False
		}
		ends
			and bytes.len() <= 63
			and bytes.all(|b| alphanumeric(b) or b == '-' or b == '_')
	}

	## Machine `m`'s networking.hostName: HostName, else its instance's name.
	host_name : Machine -> Str
	host_name = |m| if (m.host_name.is_empty()) m.instance else m.host_name

	## Machine `m` in kai's words: "machine web", or "machine web as demo"
	## for an instance.
	called : Machine -> Str
	called = |m|
		if m.instance == m.name {
			"machine ${m.name}"
		} else {
			"machine ${m.name} as ${m.instance}"
		}

	## Machine `m` as a command names it: "web", or "web --as demo".
	named : Machine -> Str
	named = |m|
		if (m.instance == m.name) m.name else "${m.name} --as ${m.instance}"

	name_one = "name one machine: kai machine ACTION NAME"

	## The machine `kai secret ACTION MACHINE [SECRET]` names, which has
	## Operators to encrypt to, and the secret a `set` names ("" for a
	## `rekey`), which the machine declares.
	secret_target :
		List(Machine), Command.Args -> Try((Machine, Str), Plan.Failure)
	secret_target = |machines, args| {
		action = Command.name(args, "action")
		words = Command.trailing(args, "names")
		usage = "kai secret set MACHINE SECRET, or kai secret rekey MACHINE"
		(name, secret) = match words {
			[machine_name, secret_name] if action == "set" => (machine_name, secret_name)
			[machine_name] if action == "rekey" => (machine_name, "")
			_ => return Err(Plan.fail("name what to ${action}: ${usage}"))
		}
		unknown = |message, given, names| {
			code: "unknown_name",
			message,
			hint: "",
			suggestions: Plan.closest(given, names),
		}
		machine_names = machines.map(|found| found.name)
		declared = machines.find_first(|found| found.name == name).map_err(
			|_| unknown("unknown machine: ${name}", name, machine_names),
		)?
		m = MachineModel.instance_of(machines, declared, args).map_err(Plan.fail)?
		secrets = m.secrets.map(|s| s.name)
		if m.operators.is_empty() {
			Err(Plan.fail("machine ${name} has no Operators to encrypt secrets to"))
		} else if action == "set" and !secrets.contains(secret) {
			Err(unknown("machine ${name} declares no secret ${secret}", secret, secrets))
		} else {
			Ok((m, secret))
		}
	}

	## Where `kai machine ACTION` acts on machine `m`: `--to`, else its Host,
	## else the host kai runs on. A build is always made here, and an
	## install, which erases a disk, goes only where `--to` says. Host is
	## the machine's own server, never an instance's.
	destination : Machine, Command.Args -> Try([Here, Remote(Str)], Str)
	destination = |m, args| {
		action = Command.name(args, "action")
		match Command.value(args, "to") {
			Ok(_) if action == "build" =>
				Err("kai machine build builds here and takes no --to")
			Ok(to) if !MachineModel.valid_target(to) =>
				Err("--to ${to} is no SSH target; ${MachineModel.target_form}")
			Ok(to) => Ok(Remote(to))
			Err(NoValue) if action == "install" =>
				Err(
					"kai machine install ${MachineModel.named(m)} needs --to TARGET, "
						.concat("such as root@203.0.113.7: it erases the target's disk, ")
						.concat("so it never defaults to Host"),
				)
			Err(NoValue) if m.host.is_empty() or m.instance != m.name => Ok(Here)
			Err(NoValue) => Ok(Remote(m.host))
		}
	}

	## Why machine `m` cannot be installed on a server, if it cannot: an
	## install partitions its Disk, and the server must accept SSH logins
	## afterwards.
	installable : Machine -> Try({}, Str)
	installable = |m|
		if m.disk == NoDisk {
			Err(
				"kai machine install needs Disk(...) on machine ${m.name}, "
					.concat("the disk it partitions and installs on"),
			)
		} else if !m.ssh {
			# Ssh needs a User with SshKeys, so this checks both.
			Err(
				"kai machine install needs Ssh and a User with SshKeys on machine "
					.concat("${m.name}, or the server cannot be reached once installed"),
			)
		} else {
			Ok({})
		}

	target_form = "use host or user@host, then :port for a port other than 22, "
		.concat("with an IPv6 host in brackets, such as root@[2001:db8::1]:2222")

	## An SSH target's parts: the user, "" when ssh chooses it; the host, a
	## name or an IPv4 or IPv6 address, without brackets; and the port, ""
	## for ssh's own, which ~/.ssh/config may set.
	Target : { user : Str, host : Str, port : Str }

	## Parses an SSH target, `host` or `user@host`, then `:port` for a port
	## from 1 to 65535. An IPv6 host stands bare, or in brackets, which a
	## port needs. The host never starts with `-`, so ssh cannot read it as
	## an option.
	parse_target : Str -> Try(Target, [NotTarget])
	parse_target = |target| {
		(user, address) = match target.split_first("@") {
			Ok({ before, after }) if MachineModel.valid_account(before) =>
				(before, after)
			Ok(_) => return Err(NotTarget)
			Err(_) => ("", target)
		}
		colons = |text| text.to_utf8().keep_if(|b| b == ':').len()
		# The port follows a colon, or "" stands for none.
		(host, port) = if address.starts_with("[") {
			match address.drop_prefix("[").split_first("]") {
				Ok({ before, after }) if colons(before) >= 2 => (before, after)
				_ => return Err(NotTarget)
			}
		} else if colons(address) == 1 {
			match address.split_first(":") {
				Ok({ before, after }) => (before, ":${after}")
				Err(_) => return Err(NotTarget)
			}
		} else {
			# Two colons or more are a bare IPv6 address.
			(address, "")
		}
		host_byte = |b|
			(b >= 'a' and b <= 'z')
				or (b >= 'A' and b <= 'Z')
				or (b >= '0' and b <= '9')
				or ".-_:".to_utf8().contains(b)
		number = port.drop_prefix(":")
		valid_host = !host.is_empty()
			and !host.starts_with("-")
			and host.to_utf8().all(host_byte)
		valid_port = port.is_empty()
			or (port.starts_with(":") and Caddy.valid_port(number))
		if valid_host and valid_port {
			Ok({ user, host, port: number })
		} else {
			Err(NotTarget)
		}
	}

	## Whether `target` is an SSH target, as `parse_target` takes.
	valid_target : Str -> Bool
	valid_target = |target| MachineModel.parse_target(target).is_ok()

	## The user a target names, or "" when ssh chooses it.
	target_user : Str -> Str
	target_user = |target|
		match MachineModel.parse_target(target) {
			Ok({ user, .. }) => user
			Err(NotTarget) => ""
		}

	## A user or group name: a-z or _, then at most 31 of a-z, 0-9, _ or -.
	valid_account : Str -> Bool
	valid_account = |name| {
		lower = |b| b >= 'a' and b <= 'z'
		digit = |b| b >= '0' and b <= '9'
		match name.to_utf8() {
			[first, .. as rest] =>
				(lower(first) or first == '_')
					and rest.len() < 32
					and rest.all(|b| lower(b) or digit(b) or b == '_' or b == '-')
			[] => Bool.False
		}
	}
}
