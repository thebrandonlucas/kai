import Host
import Stdout

## Kai protocol helpers and modular config dispatch.
Kai := [].{
	# `packages` is a Roc header keyword in this compiler, so shell configs use `pkgs`.
	ShellConfig : { name : Str, pkgs : List(Str) }

	MachineBuildConfig : {
		hostname : Str,
		system : Str,
		install : List(Str),
		ssh_keys : List(Str),
		state_version : Str,
		image : { format : Str },
	}

	ConfigEntry : [
		Shell({ name : Str, pkgs : List(Str) }),
		MachineBuild({
			hostname : Str,
			system : Str,
			install : List(Str),
			ssh_keys : List(Str),
			state_version : Str,
			image : { format : Str },
		}),
	]

	## Run a config-style Kai app.
	##
	## The app supplies only the protocol command entries it needs.
	runConfig! : List(Str), List(ConfigEntry) => I32
	runConfig! = |args, config| {
		command = requestedCommand(args)

		if command == "machine.build" {
			match findMachineBuild(config) {
				Ok(build) => runMachineBuild!(build)
				Err(_) => missingConfigCommand!("machine.build")
			}
		} else if command == "build" {
			match findMachineBuild(config) {
				Ok(build) => runMachineBuild!(build)
				Err(_) => missingConfigCommand!("machine.build")
			}
		} else if command == "shell" {
			match findShell(config) {
				Ok(shell) => runShell!(shell)
				Err(_) => missingConfigCommand!("shell")
			}
		} else {
			_ = Stdout.line!("kai: command not available: ${command}")
			1
		}
	}

	requestedCommand : List(Str) => Str
	requestedCommand = |args|
		match List.get(args, 1) {
			Ok(command) => command
			Err(_) => "shell"
		}

	findShell = |entries|
		match entries {
			[] => Err({})
			[first, .. as rest] =>
				match first {
					Shell(shell) => Ok(shell)
					MachineBuild(_) => findShell(rest)
				}
		}

	findMachineBuild = |entries|
		match entries {
			[] => Err({})
			[first, .. as rest] =>
				match first {
					MachineBuild(build) => Ok(build)
					Shell(_) => findMachineBuild(rest)
				}
		}

	missingConfigCommand! : Str => I32
	missingConfigCommand! = |command| {
		_ = Stdout.line!("kai: config does not define command: ${command}")
		1
	}

	## Run the `shell` config entry.
	runShell! : ShellConfig => I32
	runShell! = |shell| {
		Host.kai_config_shell!(shell.name, shell.pkgs)
	}

	## Build the `machine.build` config entry.
	runMachineBuild! : MachineBuildConfig => I32
	runMachineBuild! = |build|
		Host.kai_machine_build!(build.hostname, build.system, build.install, build.ssh_keys, build.state_version, build.image.format)

	## Emit the portable `shell` protocol command using the selected backend.
	shell! : { target : Str, command : List(Str) } => Str
	shell! = |spec|
		Host.kai_shell!("", "shell", spec.target, spec.command)

	## Emit `shell` using an explicit backend name or adapter executable path.
	shellWithAdapter! : { adapter : Str, target : Str, command : List(Str) } => Str
	shellWithAdapter! = |spec|
		Host.kai_shell!(spec.adapter, "shell", spec.target, spec.command)
}
