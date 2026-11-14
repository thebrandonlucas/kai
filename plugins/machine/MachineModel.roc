# The machines a Kaifile declares, as every backend's implementation of the
# machine command reads them.
import pf.Command

MachineModel :: [].{

	## A machine's settings, folded. Modules is Nix's alone: the nix
	## implementation checks it, and another backend would refuse it.
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
}
