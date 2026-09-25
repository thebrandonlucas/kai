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
		(kai, project) = KaiUpdate.fixture!(
			binary,
			"composition",
			["ProjectTasks.roc"],
		)?
		result = KaiUpdate.run_in!(kai, project)
		Path.delete_all!(project)?
		result
	}

	# A temporary copy of an example's Kaifile.roc and listed files or
	# directories (symlinks preserved), plus the absolute kai binary.
	fixture! = |binary, example, entries| {
		root = Path.canonicalize!(Env.cwd!()?)?
		kai = Path.canonicalize!(Path.utf8(binary))?
		temporary = Env.create_temp_dir_with_prefix!("kai-fixture-")?
		project = Path.canonicalize!(temporary)?
		source = Path.join(root, "examples/${example}")
		kaifile = Path.read_utf8!(Path.join(source, "Kaifile.roc"))?
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

	run_in! = |kai, project| {
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
