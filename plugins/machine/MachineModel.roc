# The machines a Kaifile declares, as every backend's implementation of the
# machine command reads them.
import pf.Command

MachineModel :: [].{

	## A machine's settings, folded. Modules is Nix's alone: the nix
	## implementation checks it, and another backend would refuse it. `host`
	## is the SSH target it lives at, "" for the host kai runs on. `disk` is
	## the layout install partitions and the system mounts.
	Machine : {
		name : Str,
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
		modules : List(Str),
	}

	## No disk layout, or the whole disk at a device path.
	Disk : [NoDisk, SingleDisk(Str)]

	User : { name : Str, keys : List(Str), groups : List(Str) }

	## The machine `kai machine ACTION NAME` names.
	requested : List(Machine), Command.Args -> Try(Machine, Str)
	requested = |machines, args| {
		name = match Command.trailing(args, "machine") {
			[one] => one
			_ => return Err(MachineModel.name_one)
		}
		machines
			.find_first(|m| m.name == name)
			.map_err(|_| "unknown machine: ${name}")
	}

	name_one = "name one machine: kai machine ACTION NAME"

	## Where `kai machine ACTION` acts on machine `m`: `--to`, else its Host,
	## else the host kai runs on. A build is always made here, and an
	## install, which erases a disk, goes only where `--to` says.
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
					"kai machine install ${m.name} needs --to TARGET, such as "
						.concat("root@203.0.113.7: it erases the target's disk, so ")
						.concat("it never defaults to Host"),
				)
			Err(NoValue) if m.host.is_empty() => Ok(Here)
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

	target_form = "use user@host or host, without a port"

	## An SSH target both `ssh` and `nix copy --to ssh-ng://` take: `host` or
	## `user@host`, where host is a name or an IPv4 or IPv6 address, and a
	## port comes from ~/.ssh/config. It never starts with `-`, so ssh cannot
	## read it as an option.
	valid_target : Str -> Bool
	valid_target = |target| {
		(user, host) = match target.split_first("@") {
			Ok({ before, after }) => (Ok(before), after)
			Err(_) => (Err(NoUser), target)
		}
		host_byte = |b|
			(b >= 'a' and b <= 'z')
				or (b >= 'A' and b <= 'Z')
				or (b >= '0' and b <= '9')
				or ".-_:".to_utf8().contains(b)
		# A single colon is a port, which ssh would read as part of the name.
		colons = host.to_utf8().keep_if(|b| b == ':').len()
		valid_user = match user {
			Ok(name) => MachineModel.valid_account(name)
			Err(NoUser) => Bool.True
		}
		valid_user
			and !host.is_empty()
			and !host.starts_with("-")
			and host.to_utf8().all(host_byte)
			and colons != 1
	}

	## The user a target names, or "" when ssh chooses it.
	target_user : Str -> Str
	target_user = |target|
		match target.split_first("@") {
			Ok({ before, .. }) => before
			Err(_) => ""
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
