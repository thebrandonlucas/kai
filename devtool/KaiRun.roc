# Run a built `kai run` and `kai shell` against real Nix on a copy of
# examples/composition: without a lock they refuse and create none; with one
# they pass exact argv, keep a task's exit code and leave the lock untouched,
# even though the Kaifile.roc has warnings.
import pf.Cmd
import pf.Path
import pf.Stdout

import KaiUpdate

KaiRun := [].{
	run! = |binary| {
		(kai, project) = KaiUpdate.fixture!(binary)?
		result = KaiRun.run_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	# roc exits 2 after evaluating a Kaifile.roc with warnings.
	warned =
		\\
		\\warned = |x| {
		\\	unused = 1
		\\	x
		\\}
		\\

	run_in! = |kai, project| {
		kaifile = Path.join(project, "Kaifile.roc")
		Path.write_utf8!(kaifile, Path.read_utf8!(kaifile)?.concat(KaiRun.warned))?
		lock = Path.join(project, ".kai/lock.json")
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(project)
			.exec_output!()
		checked = kai!(["check"])?
		shown = checked.stdout_utf8.concat(checked.stderr_utf8_lossy)
		if !shown.contains("unused variable") {
			return Err(WarningNotShown)
		}
		match kai!(["run", "args"]) {
			Err(NonZeroExitCode({ exit_code, stderr_utf8_lossy, .. })) if exit_code == 1
				and stderr_utf8_lossy.contains("run `kai update`") => {}
			other => return Err(RanWithoutLock(Str.inspect(other)))
		}
		if Path.exists!(lock)? {
			return Err(LockCreatedWithoutUpdate)
		}
		_ = kai!(["update"])?
		published = Path.read_bytes!(lock)?
		modified = Path.time_modified!(lock)?
		args = kai!(["run", "args", "--", "first", "two words", "--literal", ""])?
		expected = "<configured argument><first><two words><--literal><>\n"
		if args.stdout_utf8 != expected {
			return Err(WrongArgv(args.stdout_utf8))
		}
		shell = kai!(["shell", "default", "--", "git", "--version"])?
		if !shell.stdout_utf8.starts_with("git version ") {
			return Err(WrongShellOutput(shell.stdout_utf8))
		}
		match kai!(["run", "fail"]) {
			Err(NonZeroExitCode({ exit_code, .. })) if exit_code == 7 => {}
			other => return Err(LostExitCode(Str.inspect(other)))
		}
		if
			Path.read_bytes!(lock)? != published
				or Path.time_modified!(lock)? != modified
				{
					return Err(LockChanged)
				}
		Stdout.line!("kai run and shell kept argv, exit codes and the lock")
	}
}
