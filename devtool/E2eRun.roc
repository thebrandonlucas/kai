# kai run and kai shell. On Nix, on a copy of examples/composition: without a
# lock they refuse and create none; with one they pass exact argv, keep a
# task's exit code, run raw shell hooks, print a dry run's plan without
# running it and leave the lock untouched, even though the Kaifile.roc has
# warnings. On Guix: STUBBED process-boundary checks on examples/channels
# show that Guix commands need a Guix lock, then run under `guix
# time-machine` at the locked channels with exact argv, and that a failing
# Guix shell never falls back to Nix; then real Guix runs a shell and a task
# on examples/composition and the channel source's shell on examples/channels.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout

import E2e

E2eRun := [].{
	nix! = |binary| {
		(kai, project) = E2e.fixture!(
			binary,
			"composition",
			["ProjectTasks.roc"],
		)?
		result = E2eRun.nix_in!(kai, project)
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

	# roc exits 2 after evaluating a Kaifile.roc with warnings.
	warned =
		\\
		\\warned = |x| {
		\\	unused = 1
		\\	x
		\\}
		\\

	nix_in! = |kai, project| {
		kaifile = Path.join(project, "Kaifile.roc")
		shell = "\tShell(\"default\", [Use(\"dev\")]),\n"
		config = match Path.read_utf8!(kaifile)?.split_on(shell) {
			[before, after] =>
				"${before}${shell}${E2eRun.extra}\n${after}${E2eRun.warned}"
			_ => return Err(UnexpectedKaifileShell)
		}
		Path.write_utf8!(kaifile, config)?
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
		# A dry run prints the plan and runs nothing; the task would exit 7.
		dry = kai!(["--dry-run", "--yes", "run", "fail"])?
		if !dry.stdout_utf8.contains("(Run ") {
			return Err(DryRunShowedNoPlan(dry.stdout_utf8))
		}
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

	guix! = |bare, guix| {
		(kai, project) = E2e.fixture!(bare, "channels", [])?
		stubs = Path.canonicalize!(Env.create_temp_dir_with_prefix!("kai-stubs-")?)?
		stubbed = E2eRun.stubbed!(kai, project, stubs)
		Path.delete_all!(stubs)?
		Path.delete_all!(project)?
		stubbed?
		match guix {
			Missing => E2e.skipped!("kai run and shell")
			Ready(path) => {
				composed = [
					(["shell", "default", "--", "echo", "a b"], "a b\n"),
					(["run", "args", "--", "a b"], "<configured argument><a b>\n"),
				]
				E2eRun.guix_on!(bare, path, "composition", composed)?
				greeting = ["hello", "--greeting", "hi"]
				shell = ["--backend", "guix", "shell", "channels", "--"]
				channels = [(shell.concat(greeting), "hi\n")]
				E2eRun.guix_on!(bare, path, "channels", channels)?
				Stdout.line!("kai ran pinned Guix shells and tasks without Nix")
			}
		}
	}

	## Run each case on a pinned copy of `example` and compare its stdout.
	guix_on! = |bare, path, example, cases| {
		entries = if example == "composition" ["ProjectTasks.roc"] else []
		(kai, project) = E2e.guix_project!(bare, example, entries)?
		result = E2eRun.guix_in!(kai, project, path, cases)
		Path.delete_all!(project)?
		result
	}

	stubbed! = |kai, project, stubs| {
		roc = "${E2e.which!("roc")?}/roc"
		log = Path.join(stubs, "log")
		Path.write_utf8!(Path.join(stubs, "nix"), E2e.stub("nix", "1"))?
		Path.write_utf8!(Path.join(stubs, "guix"), E2e.stub("guix", "0"))?
		Cmd.new_str("chmod").args_str(["+x", "nix", "guix"]).cwd(stubs)
			.exec_cmd!()?
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args)
			.cwd(project)
			.env_str("PATH", Path.display(stubs))
			.env_str("ROC", roc)
			.env_str("KAI_STUB_LOG", Path.display(log))
			.exec_output!()
		command = ["hello", "--greeting", "two words"]
		match kai!(["shell", "default", "--"].concat(command)) {
			Err(NonZeroExitCode({ exit_code, stderr_utf8_lossy, .. })) if exit_code == 1
				and stderr_utf8_lossy.contains("run kai --backend guix update") => {}
			other => return Err(GuixRanUnlocked(Str.inspect(other)))
		}
		E2e.pin!(project)?
		generated = Path.join(project, ".kai/generated/guix/channels.scm")
		channels = Path.display(generated)
		stubbed = [
			(
				["shell", "default", "--"].concat(command),
				["nix --version", "guix --version"],
			),
			(
				["--backend", "guix", "shell", "channels", "--"].concat(command),
				["guix --version"],
			),
		]
		for (args, probes) in stubbed {
			Path.write_utf8!(log, "")?
			match kai!(args) {
				Err(NonZeroExitCode({ exit_code, .. })) if exit_code == 3 => {}
				other => return Err(GuixStatusLost(Str.inspect(other)))
			}
			argv = ["time-machine", "-C", channels, "--"]
				.concat(["shell", "-q", "--pure", "hello", "--"])
				.concat(command)
			expected = probes.concat(argv.map(|arg| "guix ${arg}"))
			recorded = Path.read_utf8!(log)?.split_on("\n").drop_last(1)
			if recorded != expected {
				return Err(WrongGuixArgv(recorded))
			}
		}
		if !Path.read_utf8!(generated)?.contains(E2e.release) {
			return Err(ChannelsNotPinned)
		}
		Stdout.line!("stubbed kai ran guix under time-machine with exact argv")
	}

	guix_in! = |kai, project, path, cases| {
		for (args, expected) in cases {
			output = E2e.guix_kai!(kai, project, path, args)?
			if output.stdout_utf8 != expected {
				return Err(WrongGuixShell(Str.inspect(output)))
			}
		}
		Ok({})
	}
}
