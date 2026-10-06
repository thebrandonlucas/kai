# kai update. On Nix, on a copy of examples/composition: it must publish a
# decodable lock, keep another backend's section, succeed again, and refuse
# to publish while another update holds the writer lock. On Guix, on a copy
# of examples/composition with Nix off PATH: it locks the Guix channels alone.
import pf.Cmd
import pf.Path
import pf.Stderr
import pf.Stdout
import api.LockJson
import nix.Locks

import E2e

E2eUpdate := [].{
	nix! = |binary| {
		(kai, project) = E2e.fixture!(
			binary,
			"composition",
			["ProjectTasks.roc"],
		)?
		result = E2eUpdate.nix_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	nix_in! = |kai, project| {
		lock = Path.join(project, ".kai/lock.json")
		nix_update = ["--backend", "nix", "update"]
		update! = || Cmd.new(Path.to_os_str(kai)).args_str(nix_update)
			.cwd(project).exec_cmd!()
		update!()?
		_ = Locks.decode(Path.read_utf8!(lock)?).map_err(|err| BadLock(err))?
		# A Nix update keeps another backend's section as it is.
		guix = LockJson.Object([{ name: "channels", value: LockJson.Array([]) }])
		decoded = |text| LockJson.decode(text).map_err(|err| BadLock(err))
		sections = LockJson.object(decoded(Path.read_utf8!(lock)?)?)
			.map_err(|err| BadLock(err))?
		with_guix = LockJson.Object(sections.append({ name: "guix", value: guix }))
		Path.write_utf8!(lock, LockJson.encode(with_guix))?
		update!()?
		kept = LockJson.field(decoded(Path.read_utf8!(lock)?)?, "guix")
		if kept != Ok(guix) {
			return Err(GuixSectionLost(Str.inspect(kept)))
		}
		published = Path.read_bytes!(lock)?
		_ = Locks.decode(Path.read_utf8!(lock)?).map_err(|err| BadLock(err))?
		guard = Path.join(project, ".kai/lock.json.lock")
		Path.create_dir!(guard)?
		Stderr.line!("expecting kai update to refuse the held writer lock:")?
		match update!() {
			Err(ExecCmdFailed(_)) => {}
			other => return Err(UpdateIgnoredLock(Str.inspect(other)))
		}
		if Path.read_bytes!(lock)? != published {
			return Err(LockChangedWhileHeld)
		}
		Path.delete_empty!(guard)?
		Stdout.line!(
			"kai update published, refreshed, kept the guix section and "
				.concat("respected its lock"),
		)
	}

	guix! = |bare, guix|
		match guix {
			Missing => E2e.skipped!("kai update")
			Ready(path) => {
				(kai, project) = E2e.fixture!(bare, "composition", ["ProjectTasks.roc"])?
				result = E2eUpdate.guix_in!(kai, project, path)
				Path.delete_all!(project)?
				result
			}
		}

	guix_in! = |kai, project, path| {
		_ = E2e.guix_kai!(kai, project, path, ["update"])?
		locked = Path.read_utf8!(Path.join(project, ".kai/lock.json"))?
		if !locked.contains("\"guix\"") or locked.contains("\"nix\"") {
			return Err(WrongGuixLock(locked))
		}
		Stdout.line!("kai update locked the Guix channels without Nix")
	}
}
