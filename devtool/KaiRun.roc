# Run a built `kai run` and `kai shell` against real Nix on a copy of
# examples/composition: without a lock they refuse and create none; with one
# they pass exact argv, keep a task's exit code, run raw shell hooks and
# leave the lock untouched.
import pf.Cmd
import pf.Path
import pf.Stdout

import KaiUpdate

KaiRun := [].{
	run! = |binary| {
		(kai, project) = KaiUpdate.fixture!(
			binary,
			"composition",
			["ProjectTasks.roc"],
		)?
		result = KaiRun.run_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	# A build, a workflow and a raw shell hook beside the example's settings;
	# a --opt=dev kai crashed on one task argument and dropped the hook.
	extra =
		\\	Build("copy", [Use("dev"), Run(["cp", "Kaifile.roc", "out"]),
		\\		Output("out")]),
		\\	Workflow("ci", [RunTask("test", []), BuildArtifact("copy")]),
		\\	Raw("nix", "shell:default", Attrs([("shellHook",
		\\		Str("export KAI_HOOK='ran from the raw shell hook'"))])),

	run_in! = |kai, project| {
		kaifile = Path.join(project, "Kaifile.roc")
		shell = "\tShell(\"default\", [Use(\"dev\")]),\n"
		config = match Path.read_utf8!(kaifile)?.split_on(shell) {
			[before, after] => "${before}${shell}${KaiRun.extra}\n${after}"
			_ => return Err(UnexpectedKaifileShell)
		}
		Path.write_utf8!(kaifile, config)?
		lock = Path.join(project, ".kai/lock.json")
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(project)
			.exec_output!()
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
		one = kai!(["run", "args", "--", "one"])?
		if one.stdout_utf8 != "<configured argument><one>\n" {
			return Err(WrongArgv(one.stdout_utf8))
		}
		git = kai!(["shell", "default", "--", "git", "--version"])?
		if !git.stdout_utf8.starts_with("git version ") {
			return Err(WrongShellOutput(git.stdout_utf8))
		}
		hooked = kai!(["shell", "default", "--", "printenv", "KAI_HOOK"])?
		if hooked.stdout_utf8 != "ran from the raw shell hook\n" {
			return Err(ShellHookNotRun(hooked.stdout_utf8))
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
