import Host
import Stdout

## Kai shell protocol helpers.
##
## Roc code emits only the backend-neutral `shell` command. The Zig host sends
## the request to a selected backend adapter executable, receives an argv plan,
## and executes that argv directly.
Kai := [].{

	## Run a config-style Kai app.
	##
	## The app supplies declarative `shell` and `machine.build` sections.
	## Adapter selection for `shell` comes from `.kai-adapter` or
	## `KAI_BACKEND_ADAPTER`.
	runConfig! : List(Str),
	{
		shell : { environment : Str, run : Str },
		machine : {
			build : {
				hostname : Str,
				system : Str,
				install : List(Str),
				ssh_keys : List(Str),
				state_version : Str,
				image : { format : Str },
			},
		},
	} => I32
	runConfig! = |args, config|
		if List.contains(args, "build") {
			runMachineBuild!(config.machine.build)
		} else {
			runShell!(config.shell)
		}

	## Run the `shell` config section.
	runShell! : { environment : Str, run : Str } => I32
	runShell! = |shell| {
		output = Host.kai_shell!("", "shell", shell.environment, ["sh", "-c", shell.run])
		Stdout.line!(output)
		0
	}

	## Build the `machine.build` config section.
	runMachineBuild! : {
		hostname : Str,
		system : Str,
		install : List(Str),
		ssh_keys : List(Str),
		state_version : Str,
		image : { format : Str },
	} => I32
	runMachineBuild! = |build|
		Host.kai_machine_build!(build.hostname, build.system, build.install, build.ssh_keys, build.state_version, build.image.format)

	## Emit the portable `shell` protocol command using the adapter selected by
	## `.kai-adapter` or `KAI_BACKEND_ADAPTER`.
	shell! : { target : Str, command : List(Str) } => Str
	shell! = |spec|
		Host.kai_shell!("", "shell", spec.target, spec.command)

	## Emit `shell` using an explicit adapter executable path, built-in adapter
	## name (`nix` or `guix`), or PATH name.
	shellWithAdapter! : { adapter : Str, target : Str, command : List(Str) } => Str
	shellWithAdapter! = |spec|
		Host.kai_shell!(spec.adapter, "shell", spec.target, spec.command)
}
