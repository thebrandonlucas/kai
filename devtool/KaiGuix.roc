# Run a built `kai shell` against Guix on a copy of examples/guix. STUBBED
# process-boundary checks come first: recording stand-ins for guix and nix
# show the selected program, exact argv, and that a failing Guix shell never
# falls back to Nix. Then, when guix is installed, real Guix shells run with
# Nix absent from PATH and no lock is created. A missing guix is reported as
# skipped, never passed, and fails when the real run is required.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout

import KaiUpdate

KaiGuix := [].{
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
	# every shell with status 3.
	stub = |name, status|
		\\#!/bin/sh
		\\# STUB for kai-guix: records argv and runs nothing.
		\\for arg in "$@"; do printf '${name} %s\n' "$arg" >> "$KAI_STUB_LOG"; done
		\\[ "$1" = --version ] && exit ${status}
		\\exit 3
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
			argv = ["shell", "--pure", "hello", "--"].concat(command)
			expected = probes.concat(argv.map(|arg| "guix ${arg}"))
			recorded = Path.read_utf8!(log)?.split_on("\n").drop_last(1)
			if recorded != expected {
				return Err(WrongGuixArgv(recorded))
			}
		}
		Stdout.line!("stubbed kai shell ran guix with exact argv, no fallback")?
		guix = match KaiGuix.which!("guix") {
			Ok(dir) => dir
			Err(_) if required => return Err(GuixNotInstalled)
			Err(_) => return Stdout.line!("SKIPPED: guix not installed")
		}
		# guix can share a directory with nix (as on NixOS), so PATH holds only
		# a link to guix; Roc stays reachable through ROC.
		isolated = Path.join(stubs, "guix-only")
		Path.create_dir!(isolated)?
		Cmd.new_str("ln")
			.args_str(["-s", "${guix}/guix", Path.display(isolated)])
			.exec_cmd!()?
		guix_path = Path.display(isolated)
		auto = kai!(
			guix_path,
			["shell", "default", "--", "hello", "--greeting", "a b"],
		)?
		if
			auto.stdout_utf8 != "a b\n"
				or !auto.stderr_utf8_lossy.contains("not pinned by Kai's lock")
				{
					return Err(WrongGuixShell(Str.inspect(auto)))
				}
		named = [["--backend", "guix", "shell", "default"], ["shell", "channels"]]
		for args in named {
			output = kai!(guix_path, args.concat(["--", "hello", "--greeting", "hi"]))?
			if output.stdout_utf8 != "hi\n" {
				return Err(WrongGuixShell(Str.inspect(output)))
			}
		}
		match kai!(guix_path, ["--backend", "guix", "update"]) {
			Err(NonZeroExitCode({ exit_code, stderr_utf8_lossy, .. })) if exit_code == 1
				and stderr_utf8_lossy.contains("locking is not supported") => {}
			other => return Err(GuixLocked(Str.inspect(other)))
		}
		if Path.exists!(Path.join(project, ".kai"))? {
			return Err(GuixCreatedWorkspace)
		}
		Stdout.line!("kai shell ran real Guix without Nix and created no lock")
	}
}
