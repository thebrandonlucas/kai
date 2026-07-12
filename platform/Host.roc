## Internal hosted-effect boundary for the Kai platform.
## Applications should import `Kai` and `Stdout` instead.
Host := [].{
	# adapter, protocol command, target, command argv
	kai_shell! : Str, Str, Str, List(Str) => Str
	# shell name, packages
	kai_config_shell! : Str, List(Str) => I32
	# hostname, system, packages, ssh keys, state version, image format
	kai_machine_build! : Str, Str, List(Str), List(Str), Str, Str => I32
	stdout_line! : Str => {}
}
