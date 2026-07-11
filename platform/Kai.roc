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
	## The app supplies only declarative shell configuration; adapter selection
	## comes from `.kai-adapter` or `KAI_BACKEND_ADAPTER`.
	runConfig! : { shell : { environment : Str, run : Str }, stdout : Str } => I32
	runConfig! = |config| {
		output = Host.kai_shell!("", "shell", config.shell.environment, ["sh", "-c", config.shell.run])

		if output == config.stdout {
			Stdout.line!(output)
			0
		} else {
			Stdout.line!("expected stdout ${config.stdout}, got: ${output}")
			1
		}
	}

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
