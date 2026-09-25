# `kai update`: the only command that resolves pins and publishes the lock
# authority. Every other command reads the authority and never writes it.
import pf.Cmd
import pf.Env

import ir.Ir
import ir.Layout
import nix.NixBackend
import nix.Locks

import Workspace

Update := [].{
	# The system the generated flake is evaluated for; Load.check_host! checks
	# the separate build host that evaluates Kaifile.roc.
	target = "x86_64-linux"

	update! : Ir, Layout => Try({}, _)
	update! = |ir, layout| {
		files = NixBackend.update_files(ir, Update.target, layout)
			.map_err(|message| RenderFailed(message))?
		locals = NixBackend.local_checks(ir, Update.target, layout)
			.map_err(|message| RenderFailed(message))?
		Workspace.prepare!(layout)?
		prior = Update.observe!(layout.lock_path)?
		# Reject ancestor escapes and nested symlinks before staging or fetching.
		for local in locals {
			Workspace.safe_source!(local)?
		}
		backend_lock = "${layout.generated_root}/flake.lock"
		Workspace.safe_path!(backend_lock)?
		if backend_lock == layout.lock_path {
			return Err(UnsafePath(backend_lock))
		}
		Workspace.stage!(files, layout)?
		# Derived state is disposable. Unlink it rather than letting Nix follow a
		# stale hard-link alias while explicitly resolving a fresh input graph.
		if Workspace.path(backend_lock).exists!()? {
			Workspace.path(backend_lock).delete!()?
		}
		argv = ["flake", "update", "--flake", "path:${layout.generated_root}"]
		Cmd.new_str("nix").args_str(argv)
			.cwd(Workspace.path(layout.project_root))
			.exec_cmd!()?
		Workspace.safe_path!(backend_lock)?
		locks = Locks.from_nix(
			ir,
			layout,
			Workspace.path(backend_lock).read_utf8!()?,
		).map_err(|message| LockFailed(message))?
		Update.publish!(layout.lock_path, prior, Locks.encode(locks))
	}

	# The authority's bytes, so publication can detect a concurrent writer.
	observe! : Str => Try([Absent, Present(List(U8))], _)
	observe! = |lock_path| {
		Workspace.safe_path!(lock_path)?
		match Workspace.path(lock_path).type!() {
			Ok(IsFile) => Ok(Present(Workspace.path(lock_path).read_bytes!()?))
			Err(PathErr(NotFound, _)) => Ok(Absent)
			Ok(_) => Err(UnsafePath(lock_path))
			Err(err) => Err(err)
		}
	}

	# A directory created beside the authority is the writer lock. It is held
	# only while comparing the observed authority and renaming over it.
	publish! : Str, [Absent, Present(List(U8))], Str => Try({}, _)
	publish! = |lock_path, prior, contents| {
		temporary = Env.create_temp_dir_in!(
			Workspace.path(Workspace.parent(lock_path)),
			".kai-write-",
		)?
		staged = temporary.join("file")
		guard = "${lock_path}.lock"
		result = match staged.write_utf8!(contents) {
			Ok({}) =>
				match Workspace.path(guard).create_dir!() {
					Ok({}) => {
						replaced = Update.replace!(lock_path, prior, staged)
						_ = Workspace.path(guard).delete_empty!()
						replaced
					}
					Err(PathErr(AlreadyExists, _)) => Err(UpdateLocked(guard))
					Err(err) => Err(err)
				}
			Err(err) => Err(err)
		}
		_ = temporary.delete_all!()
		result
	}

	replace! = |lock_path, prior, staged| {
		if Update.observe!(lock_path)? != prior {
			return Err(AuthorityChanged)
		}
		staged.rename!(Workspace.path(lock_path))
	}
}
