# Pure backend results; only the consumer executes these constrained operations.
Plan := { steps : List(Step) }.{

	## A complete ordered sequence, not a scheduler or artifact-name cache.
	## Execute each step's operations, then stage its files, then run its argv.
	## Stop immediately on failure. Each explicit build repeats materialization.
	Step : {
		action : [Generate, Shell(Str), Run(Str), Build(Str)],
		files : List(File),
		argv : List(Str),
		artifacts : List(Artifact),
		operations : List(Operation),
	}

	File : { path : Str, contents : Str }

	## Installables are resolved by the backend, never guessed store paths.
	Artifact : {
		name : Str,
		installable : Str,
		output : Str,
		dependencies : List(Str),
	}

	## Verify all locked local trees before snapshotting or staging files.
	## Snapshot exclusions are absolute paths or VCS metadata basenames.
	## The Nix executor also publishes destination + ".isolation.json": caller
	## /proc/self/ns/{mnt,net} readlink identities, separate from source bytes.
	## InstallRunner copies the consumer's own executable to destination; the
	## backend runs it inside each build (see NixBackend.runner_command).
	## Serialize workspace use; stop on any failed materialization operation.
	Operation : [
		VerifyLocal({ path : Str, nar_hash : Str }),
		Snapshot({ root : Str, destination : Str, exclude : List(Str) }),
		InstallRunner({ destination : Str }),
	]
}
