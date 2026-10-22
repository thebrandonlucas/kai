# Commands as devtool's checks read them. basic-cli's Cmd reports a finished
# command as bytes and a status; the checks compare text and match a failing
# exit as NonZeroExitCode, with both streams, so these adapt one to the other.
import pf.Cmd
import pf.OsStr

Exec := [].{

	## A command running `program`.
	cmd : Str -> Cmd.Command
	cmd = |program| Cmd.new(OsStr.from_str(program))

	## Arguments as the OS strings Cmd takes.
	strs : List(Str) -> List(OsStr)
	strs = |args| args.map(OsStr.from_str)

	## Run `command` capturing both streams, failing unless it exits 0.
	output! = |command| {
		ran = command.run!()?
		stdout = Str.from_utf8_lossy(ran.stdout_bytes)
		stderr = Str.from_utf8_lossy(ran.stderr_bytes)
		failed = |exit_code|
			Err(
				NonZeroExitCode({
					command: ran.command,
					exit_code,
					stdout_utf8_lossy: stdout,
					stderr_utf8_lossy: stderr,
				}),
			)
		match ran.status {
			Exited(0) =>
				Ok({
					stdout_utf8: stdout,
					stderr_utf8_lossy: stderr,
					stdout_bytes: ran.stdout_bytes,
					stderr_bytes: ran.stderr_bytes,
				})
			Exited(code) => failed(code)
			Signaled(signal) => failed(128 + signal)
		}
	}

	## Run `command` on this terminal, failing unless it exits 0.
	cmd! = |command| {
		code = Exec.exit_code!(command)?
		if code == 0 {
			Ok({})
		} else {
			Err(ExecCmdFailed({ command: command.to_str(), exit_code: code }))
		}
	}

	## Run `command` on this terminal and return its exit code; a signal is
	## reported as 128 plus its number, as a shell does.
	exit_code! = |command| {
		ran = command.inherit_stdio().run!()?
		match ran.status {
			Exited(code) => Ok(code)
			Signaled(signal) => Ok(128 + signal)
		}
	}
}
