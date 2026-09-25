# Run a built `kai update` against real Nix on a copy of examples/composition:
# it must publish a decodable lock, succeed again, and refuse to publish while
# another update holds the writer lock.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stderr
import pf.Stdout
import nix.Locks

import ConfigFixtures

KaiUpdate := [].{
	run! = |binary| {
		root = Path.canonicalize!(Env.cwd!()?)?
		kai = Path.canonicalize!(Path.utf8(binary))?
		temporary = Env.create_temp_dir_with_prefix!("kai-update-")?
		workspace = Path.canonicalize!(temporary)?
		result = KaiUpdate.run_in!(root, kai, workspace)
		Path.delete_all!(workspace)?
		result
	}

	run_in! = |root, kai, project| {
		composition = Path.join(root, "examples/composition")
		kaifile = Path.read_utf8!(Path.join(composition, "Kaifile.roc"))?
		# Evaluating an app needs a relative platform path.
		platform_path = ConfigFixtures.relative(
			Path.display(project),
			Path.display(Path.join(root, "kaifile/platform/main.roc")),
		)
		header = "app [config] { pf: platform \"${platform_path}\" }"
		body = match kaifile.split_on(ConfigFixtures.composition_header) {
			[before, after] => "${before}${header}${after}"
			_ => return Err(UnexpectedCompositionHeader(kaifile))
		}
		Path.write_utf8!(Path.join(project, "Kaifile.roc"), body)?
		Path.copy!(
			Path.join(composition, "ProjectTasks.roc"),
			Path.join(project, "ProjectTasks.roc"),
		)?
		lock = Path.join(project, ".kai/lock.json")
		update! = || Cmd.new(Path.to_os_str(kai)).arg_str("update")
			.cwd(project).exec_cmd!()
		update!()?
		_ = Locks.decode(Path.read_utf8!(lock)?).map_err(|err| BadLock(err))?
		update!()?
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
		Stdout.line!("kai update published, refreshed and respected its lock")
	}
}
