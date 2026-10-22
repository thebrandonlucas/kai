# Shared setup for the end-to-end tests, which run a built kai on a copy of
# an example project against a real backend. Each E2e module has a `nix!`
# half and, when Guix supports its commands, a `guix!` half. Guix halves run
# the bare kai with a PATH holding only guix and coreutils, so Nix cannot
# leak in; a missing guix is reported as skipped, never passed.
import pf.Cmd
import pf.OsStr
import pf.Env
import pf.Path
import pf.Stdout

import Exec

import ConfigFixtures

E2e := [].{

	## The Guix 1.5.0 release commit: substitutes exist for it, so the first
	## time-machine run downloads Guix rather than building it.
	release = "230aa373f315f247852ee07dff34146e9b480aec"

	## A copy of the fixture `name` in devtool/fixtures; see `copy!`.
	fixture! = |binary, name, entries|
		E2e.copy!(binary, "devtool/fixtures/${name}", entries)

	## A temporary copy of the project in `dir`, relative to the repository:
	## its Kaifile.roc, with a header naming this checkout's platform and std,
	## and the listed files or directories (symlinks preserved), plus the
	## absolute kai binary.
	copy! = |binary, dir, entries| {
		root = Path.canonicalize!(Env.cwd!()?)?
		kai = Path.canonicalize!(Path.utf8(binary))?
		temporary = Env.create_temp_dir_with_prefix!("kai-fixture-")?
		project = Path.canonicalize!(temporary)?
		source = Path.join(root, dir)
		kaifile = Path.read_utf8!(Path.join(source, "Kaifile.roc"))?
		header = ConfigFixtures.header(root, project)
		parts = ConfigFixtures.header_parts(kaifile)?
		body = "${parts.before}${header}${parts.after}"
		Path.write_utf8!(Path.join(project, "Kaifile.roc"), body)?
		for entry in entries {
			from = Path.join(source, entry)
			to = Path.join(project, entry)
			if Path.is_dir!(from)? {
				options = { symlinks: Preserve, destination: RequireNew }
				Path.copy_dir_with!(from, to, options)?
			} else {
				Path.copy!(from, to)?
			}
		}
		Ok((kai, project))
	}

	## The PATH directory holding a program, or an error if none does.
	which! = |program| {
		for dir in (Env.var_str!("PATH") ?? "").split_on(":") {
			if !dir.is_empty() and Path.exists!(Path.join(Path.utf8(dir), program))? {
				return Ok(dir)
			}
		}
		Err(NotOnPath(program))
	}

	## A directory for PATH holding links to guix and the coreutils kai
	## snapshots builds with, as any host has; Missing without guix, which
	## fails when `required`. guix can share a directory with nix (as on
	## NixOS), so linking keeps Nix off PATH.
	guix! = |required| {
		guix = match E2e.which!("guix") {
			Ok(dir) => dir
			Err(_) if required => return Err(GuixNotInstalled)
			Err(_) => return Ok(Missing)
		}
		dir = Path.canonicalize!(Env.create_temp_dir_with_prefix!("kai-guix-")?)?
		link! = |target|
			Exec.cmd!(Exec.cmd("ln").args(Exec.strs(["-s", target, Path.display(dir)])))
		link!("${guix}/guix")?
		coreutils = E2e.which!("readlink")?
		for tool in ["cp", "chmod", "readlink", "test"] {
			link!("${coreutils}/${tool}")?
		}
		Ok(Ready(dir))
	}

	## Report a Guix half skipped because guix is not installed.
	skipped! = |what| Stdout.line!("SKIPPED: ${what} on Guix: guix not installed")

	## The bare kai on a Guix project, with only `path` on PATH; Roc stays
	## reachable through ROC.
	guix_kai! = |kai, project, path, args| {
		roc = "${E2e.which!("roc")?}/roc"
		Exec.output!(
			Cmd.new(Path.to_os_str(kai))
				.args(Exec.strs(args))
				.cwd(project)
				.env(OsStr.from_str("PATH"), OsStr.from_str(Path.display(path)))
				.env(OsStr.from_str("ROC"), OsStr.from_str(roc)),
		)
	}

	## A copy of an example, locked at `release`.
	guix_project! = |binary, example, entries| {
		(kai, project) = E2e.fixture!(binary, example, entries)?
		E2e.pin!(project)?
		Ok((kai, project))
	}

	## Lock `project` at `release`: substitutes exist for it, while the
	## branch head may not have them yet.
	pin! = |project| {
		kai_dir = Path.join(project, ".kai")
		Path.create_all!(kai_dir)?
		Path.write_utf8!(Path.join(kai_dir, "lock.json"), E2e.lock(E2e.release))
	}

	## A lock holding only a guix section pinned to `commit`.
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

	## STUB executables: each argument is logged on its own line, prefixed by
	## the program's name. `nix` is unusable; `guix` passes its probe and
	## fails every other command with status 3.
	stub = |name, status|
		\\#!/bin/sh
		\\# STUB for the Guix e2e tests: records argv and runs nothing.
		\\for arg in "$@"; do printf '${name} %s\n' "$arg" >> "$KAI_STUB_LOG"; done
		\\[ "$1" = --version ] && exit ${status}
		\\exit 3
		\\
}
