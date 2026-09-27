# Run a built kai against Guix on a copy of examples/guix. STUBBED
# process-boundary checks come first: recording stand-ins for guix and nix
# show that Guix commands need a Guix lock, then run under `guix
# time-machine` at the locked channels with exact argv, and that a failing
# Guix shell never falls back to Nix. Then, when guix is installed, real Guix
# locks the channels with Nix absent from PATH, and shells, tasks, a
# sandboxed build and a workflow run at a pinned release. A missing guix is
# reported as skipped, never passed, and fails when the real run is required.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout

import KaiUpdate

KaiGuix := [].{
	# The Guix 1.5.0 release commit: substitutes exist for it, so the first
	# time-machine run downloads Guix rather than building it.
	release = "230aa373f315f247852ee07dff34146e9b480aec"

	run! = |binary, required| {
		(kai, project) = KaiUpdate.fixture!(binary, "guix", [])?
		stubs = Path.canonicalize!(Env.create_temp_dir_with_prefix!("kai-stubs-")?)?
		result = KaiGuix.run_in!(kai, project, stubs, required)
		Path.delete_all!(stubs)?
		Path.delete_all!(project)?
		result
	}

	# The PATH directory holding a program, or an error if none does.
	which! = |program| {
		for dir in (Env.var_str!("PATH") ?? "").split_on(":") {
			if !dir.is_empty() and Path.exists!(Path.join(Path.utf8(dir), program))? {
				return Ok(dir)
			}
		}
		Err(NotOnPath(program))
	}

	# STUB executables: each argument is logged on its own line, prefixed by
	# the program's name. `nix` is unusable; `guix` passes its probe and fails
	# every other command with status 3.
	stub = |name, status|
		\\#!/bin/sh
		\\# STUB for kai-guix: records argv and runs nothing.
		\\for arg in "$@"; do printf '${name} %s\n' "$arg" >> "$KAI_STUB_LOG"; done
		\\[ "$1" = --version ] && exit ${status}
		\\exit 3
		\\

	# A lock holding only a guix section pinned to `commit`.
	lock = |commit|
		\\{"version": 2, "guix": {
		\\  "identity": {"channels": ["guix"]},
		\\  "channels": [{
		\\    "name": "guix",
		\\    "url": "https://git.guix.gnu.org/guix.git",
		\\    "branch": "master",
		\\    "commit": "${commit}",
		\\    "introduction": {
		\\      "commit": "9edb3f66fd807b096b48283debdcddccfea34bad",
		\\      "signer": "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"
		\\    }
		\\  }]
		\\}}
		\\

	run_in! = |kai, project, stubs, required| {
		roc = "${KaiGuix.which!("roc")?}/roc"
		log = Path.join(stubs, "log")
		Path.write_utf8!(Path.join(stubs, "nix"), KaiGuix.stub("nix", "1"))?
		Path.write_utf8!(Path.join(stubs, "guix"), KaiGuix.stub("guix", "0"))?
		Cmd.new_str("chmod").args_str(["+x", "nix", "guix"]).cwd(stubs)
			.exec_cmd!()?
		kai! = |path, args| Cmd.new(Path.to_os_str(kai)).args_str(args)
			.cwd(project)
			.env_str("PATH", path)
			.env_str("ROC", roc)
			.env_str("KAI_STUB_LOG", Path.display(log))
			.exec_output!()
		command = ["hello", "--greeting", "two words"]
		match kai!(Path.display(stubs), ["shell", "default", "--"].concat(command)) {
			Err(NonZeroExitCode({ exit_code, stderr_utf8_lossy, .. })) if exit_code == 1
				and stderr_utf8_lossy.contains("run kai --backend guix update") => {}
			other => return Err(GuixRanUnlocked(Str.inspect(other)))
		}
		kai_dir = Path.join(project, ".kai")
		Path.create_all!(kai_dir)?
		lock_file = Path.join(kai_dir, "lock.json")
		pin! = || Path.write_utf8!(lock_file, KaiGuix.lock(KaiGuix.release))
		pin!()?
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
			match kai!(Path.display(stubs), args) {
				Err(NonZeroExitCode({ exit_code, .. })) if exit_code == 3 => {}
				other => return Err(GuixStatusLost(Str.inspect(other)))
			}
			argv = ["time-machine", "-q", "-C", channels, "--"]
				.concat(["shell", "-q", "--pure", "hello", "--"])
				.concat(command)
			expected = probes.concat(argv.map(|arg| "guix ${arg}"))
			recorded = Path.read_utf8!(log)?.split_on("\n").drop_last(1)
			if recorded != expected {
				return Err(WrongGuixArgv(recorded))
			}
		}
		if !Path.read_utf8!(Path.utf8(channels))?.contains(KaiGuix.release) {
			return Err(ChannelsNotPinned)
		}
		Stdout.line!("stubbed kai ran guix under time-machine with exact argv")?
		guix = match KaiGuix.which!("guix") {
			Ok(dir) => dir
			Err(_) if required => return Err(GuixNotInstalled)
			Err(_) => return Stdout.line!("SKIPPED: guix not installed")
		}
		# guix can share a directory with nix (as on NixOS), so PATH holds only
		# links to guix and coreutils; Roc stays reachable through ROC.
		isolated = Path.join(stubs, "guix-only")
		Path.create_dir!(isolated)?
		Cmd.new_str("ln")
			.args_str(["-s", "${guix}/guix", Path.display(isolated)])
			.exec_cmd!()?
		# kai snapshots a build's project with coreutils, as any host has.
		coreutils = KaiGuix.which!("readlink")?
		for tool in ["cp", "chmod", "readlink", "test"] {
			Cmd.new_str("ln")
				.args_str(["-s", "${coreutils}/${tool}", Path.display(isolated)])
				.exec_cmd!()?
		}
		guix_path = Path.display(isolated)
		Path.delete!(Path.join(kai_dir, "lock.json"))?
		_ = kai!(guix_path, ["update"])?
		locked = Path.read_utf8!(Path.join(kai_dir, "lock.json"))?
		if !locked.contains("\"guix\"") or locked.contains("\"nix\"") {
			return Err(WrongGuixLock(locked))
		}
		# The release has substitutes; the branch head may not yet.
		pin!()?
		shells = [
			(["shell", "default", "--", "hello", "--greeting", "a b"], "a b\n"),
			(
				["--backend", "guix", "shell", "channels", "--"]
					.concat(["hello", "--greeting", "hi"]),
				"hi\n",
			),
			(["run", "greet", "--", "task"], "task\n"),
		]
		for (args, expected) in shells {
			output = kai!(guix_path, args)?
			if output.stdout_utf8 != expected {
				return Err(WrongGuixShell(Str.inspect(output)))
			}
		}
		# A sandboxed Guix build prints its store path; the workflow runs the
		# task, then the build.
		built = kai!(guix_path, ["--backend", "guix", "build", "greeting"])?
		path = built.stdout_utf8.trim()
		if !path.ends_with("-kai-greeting") {
			return Err(WrongGuixBuild(Str.inspect(built)))
		}
		if Path.read_utf8!(Path.utf8(path))? != "Hello, world!\n" {
			return Err(WrongGuixArtifact(path))
		}
		workflow = kai!(guix_path, ["--backend", "guix", "workflow", "ci"])?
		if !workflow.stdout_utf8.starts_with("from ci\n") {
			return Err(WrongGuixWorkflow(Str.inspect(workflow)))
		}
		Stdout.line!(
			"kai locked Guix and ran pinned Guix shells, tasks, builds and workflows "
				.concat("without Nix"),
		)
	}
}
