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

import api.LockJson

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
	copy! = |binary, dir, entries| E2e.copy_tree!(binary, dir, entries, "")

	## `copy!` of a tree whose Kaifile.roc lies in its subdirectory
	## `kaifile_dir`, or at its top when that is empty. The copy's root is
	## returned, not the Kaifile's directory.
	copy_tree! = |binary, dir, entries, kaifile_dir| {
		root = Path.canonicalize!(Env.cwd!()?)?
		kai = Path.canonicalize!(Path.utf8(binary))?
		temporary = Env.create_temp_dir_with_prefix!("kai-fixture-")?
		copy = Path.canonicalize!(temporary)?
		source = Path.join(root, dir)
		for entry in entries {
			from = Path.join(source, entry)
			to = Path.join(copy, entry)
			if Path.is_dir!(from)? {
				options = { symlinks: Preserve, destination: RequireNew }
				Path.copy_dir_with!(from, to, options)?
			} else {
				Path.copy!(from, to)?
			}
		}
		(from, project) = E2e.kaifile_dirs(source, copy, kaifile_dir)
		kaifile = Path.read_utf8!(Path.join(from, "Kaifile.roc"))?
		header = ConfigFixtures.header(root, project)
		parts = ConfigFixtures.header_parts(kaifile)?
		body = "${parts.before}${header}${parts.after}"
		Path.write_utf8!(Path.join(project, "Kaifile.roc"), body)?
		Ok((kai, copy))
	}

	## The directories holding the Kaifile in the source and in its copy.
	kaifile_dirs = |source, copy, kaifile_dir|
		if kaifile_dir.is_empty() {
			(source, copy)
		} else {
			(Path.join(source, kaifile_dir), Path.join(copy, kaifile_dir))
		}

	## `fixture!` for a Nix half; see `nix_copy!`.
	nix_fixture! = |binary, name, entries|
		E2e.nix_copy!(binary, "devtool/fixtures/${name}", entries)

	## `copy!` for a Nix half: the copy's default package source is pinned to
	## the nixpkgs Kai's own lock holds, unless the project names its own.
	nix_copy! = |binary, dir, entries| E2e.nix_copy_tree!(binary, dir, entries, "")

	## `copy_tree!` for a Nix half, pinned as `nix_copy!` pins.
	nix_copy_tree! = |binary, dir, entries, kaifile_dir| {
		(kai, copy) = E2e.copy_tree!(binary, dir, entries, kaifile_dir)?
		(_, project) = E2e.kaifile_dirs(copy, copy, kaifile_dir)
		kaifile = Path.join(project, "Kaifile.roc")
		root = Path.canonicalize!(Env.cwd!()?)?
		pinned = E2e.pin_nixpkgs(Path.read_utf8!(kaifile)?, E2e.nixpkgs!(root)?)
		Path.write_utf8!(kaifile, pinned)?
		Ok((kai, copy))
	}

	## The nixpkgs revision Kai's own .kai/lock.json locks for its default
	## package source, which the dev shell already holds. Tests pin each
	## Kaifile to it, so `kai update` reuses it rather than downloading
	## nixos-unstable whenever that moves.
	nixpkgs! = |root| {
		text = Path.read_utf8!(Path.join(root, ".kai/lock.json"))?
		bad = |err| BadKaiLock(Str.inspect(err))
		var $node = LockJson.decode(text).map_err(bad)?
		for name in ["nix", "graph", "nodes", "default", "locked", "rev"] {
			$node = LockJson.field($node, name).map_err(bad)?
		}
		LockJson.string($node).map_err(bad)
	}

	## A Kaifile with its default package source pinned to nixpkgs `rev`,
	## added before its Name setting at the same indentation; unchanged when
	## it names a default source itself.
	pin_nixpkgs : Str, Str -> Str
	pin_nixpkgs = |kaifile, rev|
		if kaifile.contains("Packages(\"default\"") {
			kaifile
		} else {
			source = "github:NixOS/nixpkgs/${rev}"
			setting = "Packages(\"default\", From(NixPackages(\"${source}\"))),"
			var $lines = []
			var $pinned = Bool.False
			for line in kaifile.split_on("\n") {
				trimmed = line.trim()
				if !$pinned and trimmed.starts_with("Name(") {
					indent = line.split_on(trimmed).first() ?? ""
					$lines = $lines.append("${indent}${setting}")
					$pinned = Bool.True
				}
				$lines = $lines.append(line)
			}
			Str.join_with($lines, "\n")
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

# The pinned default source goes before Name, at its indentation.
expect {
	pinned = E2e.pin_nixpkgs("kaifile = Std.kaifile([\n\tName(\"x\"),\n])", "abc")
	source = "github:NixOS/nixpkgs/abc"
	setting = "\tPackages(\"default\", From(NixPackages(\"${source}\"))),"
	pinned == "kaifile = Std.kaifile([\n${setting}\n\tName(\"x\"),\n])"
}

# A Kaifile naming its own default source keeps it.
expect
	E2e.pin_nixpkgs("\tPackages(\"default\", Auto),\n\tName(\"x\"),", "abc")
		== "\tPackages(\"default\", Auto),\n\tName(\"x\"),"
