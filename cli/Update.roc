# The lock authority: only a plan's PublishLock step writes it, compared and
# swapped against what that plan was planned from. Every other command reads
# it and never writes it.
import pf.Env

import Workspace

Update := [].{
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

	# The authority as the text a Kaifile plans from.
	text! : Str => Try([Absent, Present(Str)], _)
	text! = |lock_path|
		match Update.observe!(lock_path)? {
			Present(bytes) =>
				Str.from_utf8(bytes)
					.map_ok(|text| Present(text))
					.map_err(|_| BadLock(lock_path, "not UTF-8"))
			Absent => Ok(Absent)
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
