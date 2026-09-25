# Materialize one build's project snapshot: copy the filtered project tree and
# publish the caller's namespace witness beside it, replacing the previous
# snapshot only once the new one is completely staged. Symbolic links and
# special files are refused, never followed. Callers serialize workspace use
# and must not mutate the project concurrently.
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path

import Workspace

Snapshot := [].{
	# Basenames excluded at any depth, and excluded absolute trees, as bytes.
	Exclusions : { names : List(List(U8)), paths : List(List(U8)) }

	filter : List(Str) -> Try(Snapshot.Exclusions, Str)
	filter = |items| {
		names = items.keep_if(|item| !item.starts_with("/"))
		if names.any(|name| name.contains("/") or ["", ".", ".."].contains(name)) {
			return Err("snapshot exclusions must be absolute paths or names")
		}
		Ok({
			names: names.map(Str.to_utf8),
			paths: items.keep_if(|item| item.starts_with("/")).map(Str.to_utf8),
		})
	}

	# Lexical containment of raw path bytes; symlinks are checked separately.
	within : List(U8), List(U8) -> Bool
	within = |parent, child|
		if parent == ['/'] {
			child.first() == Ok('/')
		} else {
			child == parent
				or (child.take_first(parent.len()) == parent
					and child.get(parent.len()) == Ok('/'))
		}

	excluded : Snapshot.Exclusions, List(U8), List(U8) -> Bool
	excluded = |exclusions, entry, name|
		exclusions.names.contains(name)
			or exclusions.paths.any(|path| Snapshot.within(path, entry))

	# The snapshot may live in the project only beneath an excluded tree.
	check : Str, Str, Snapshot.Exclusions -> Try({}, Str)
	check = |root, destination, exclusions| {
		(project, target) = (root.to_utf8(), destination.to_utf8())
		parent = Workspace.parent(destination).to_utf8()
		if Snapshot.within(target, project) {
			Err("snapshot destination must not contain the project")
		} else if Snapshot.within(project, target)
			and !exclusions.paths.any(|path| Snapshot.within(path, parent)) {
			Err("in-tree snapshot parent must be excluded")
		} else {
			Ok({})
		}
	}

	# /proc/self/ns links read as "mnt:[4026531841]".
	identity : Str, Str -> Try(Str, Str)
	identity = |name, observed| {
		digits = observed.drop_prefix("${name}:[").drop_suffix("]")
		if
			observed == "${name}:[${digits}]"
				and !digits.is_empty()
					and digits.to_utf8().all(|b| b >= '0' and b <= '9')
				{
					Ok(observed)
				} else {
					Err("invalid caller ${name} namespace identity")
				}
	}

	# The build runner compares these with its own namespaces; kept apart from
	# the project bytes so it never changes what the project snapshot contains.
	witness_json : Str, Str -> Str
	witness_json = |mnt, net| "{\"mnt\": \"${mnt}\", \"net\": \"${net}\"}\n"

	join : List(U8), List(U8) -> List(U8)
	join = |base, relative|
		if relative.is_empty() {
			base
		} else if base.is_empty() {
			relative
		} else {
			base.append('/').concat(relative)
		}

	bytes : Path -> List(U8)
	bytes = |path|
		match Path.to_raw(path) {
			Utf8(text) => text.to_utf8()
			UnixBytes(raw) => raw
			WindowsU16s(_) => []
		}

	# Bounded argument lists for one copy or chmod invocation each.
	batches : List(a) -> List(List(a))
	batches = |items|
		items.fold(
			[],
			|groups, item|
				match groups.last() {
					Ok(group) if group.len() < 256 =>
						groups.drop_last(1).append(group.append(item))
					_ => groups.append([item])
				},
		)

	# The planned Snapshot operation.
	Request : { root : Str, destination : Str, exclude : List(Str) }

	snapshot! : Snapshot.Request => Try({}, _)
	snapshot! = |{ root, destination, exclude }| {
		isolation = "${destination}.isolation.json"
		for path in [root, destination, isolation] {
			Workspace.safe_path!(path)?
		}
		witness = Snapshot.witness_json(
			Snapshot.observe!("mnt")?,
			Snapshot.observe!("net")?,
		)
		exclusions = Snapshot.filter(exclude)
			.map_err(|message| SnapshotFailed(message))?
		for path in exclude.keep_if(|item| item.starts_with("/")) {
			Workspace.safe_path!(path)?
		}
		Snapshot.check(root, destination, exclusions)
			.map_err(|message| SnapshotFailed(message))?
		if !Workspace.path(root).is_dir!()? {
			return Err(SnapshotFailed("snapshot root is not a directory: ${root}"))
		}
		parent = Workspace.path(Workspace.parent(destination))
		parent.create_all!()?
		temporary = Env.create_temp_dir_in!(parent, ".snapshot-")?
		result = Snapshot.publish!(
			{ root, destination, isolation, witness },
			exclusions,
			temporary,
		)
		_ = temporary.delete_all!()
		result
	}

	# Readlink runs in a child, which shares this process's namespaces.
	observe! : Str => Try(Str, _)
	observe! = |name| {
		link = "/proc/self/ns/${name}"
		remedy = "cannot observe caller build isolation; use Linux with "
			.concat("readable ${link}")
		output = Cmd.new_str("readlink").args_str([link]).exec_output!()
			.map_err(|err| SnapshotFailed("${remedy}: ${Str.inspect(err)}"))?
		Snapshot.identity(name, output.stdout_utf8.trim())
			.map_err(|message| SnapshotFailed(message))
	}

	# Remove the old witness before replacing the tree, so an interrupted
	# publication cannot authorize the new tree with stale observations.
	publish! = |{ root, destination, isolation, witness }, exclusions, temporary| {
		staged = temporary.join("project")
		staged.create_dir!()?
		Snapshot.copy_tree!(root, staged, exclusions)?
		staged_witness = temporary.join("isolation.json")
		staged_witness.write_utf8!(witness)?
		Workspace.safe_path!(destination)?
		Workspace.safe_path!(isolation)?
		target = Workspace.path(destination)
		exists = match target.type!() {
			Ok(IsDir) => Bool.True
			Err(PathErr(NotFound, _)) => Bool.False
			Ok(_) => return Err(
				SnapshotFailed("snapshot destination is not a directory: ${destination}"),
			)
			Err(err) => return Err(err)
		}
		match Workspace.path(isolation).type!() {
			Ok(IsFile) => Workspace.path(isolation).delete!()?
			Err(PathErr(NotFound, _)) => {}
			Ok(_) => return Err(
				SnapshotFailed("isolation witness is not a file: ${isolation}"),
			)
			Err(err) => return Err(err)
		}
		if exists {
			target.delete_all!()?
		}
		staged.rename!(target)?
		staged_witness.rename!(Workspace.path(isolation))
	}

	# Walk with lstat, recreating directories and collecting regular files.
	# A loop rather than recursion: https://github.com/roc-lang/roc/issues/11621
	copy_tree! : Str, Path, Snapshot.Exclusions => Try({}, _)
	copy_tree! = |root, staged, exclusions| {
		(source_root, target_root) = (root.to_utf8(), Snapshot.bytes(staged))
		var $pending = [[]]
		var $files = []
		while !$pending.is_empty() {
			directory = $pending.last() ?? []
			$pending = $pending.drop_last(1)
			source = Snapshot.join(source_root, directory)
			for entry in Path.unix_bytes(source).list!()? {
				full = Snapshot.bytes(entry)
				name = full.drop_first(source.len() + 1)
				relative = Snapshot.join(directory, name)
				if !Snapshot.excluded(exclusions, full, name) {
					match entry.type!()? {
						IsDir => {
							Path.unix_bytes(Snapshot.join(target_root, relative))
								.create_dir!()?
							$pending = $pending.append(relative)
						}
						IsFile => {
							executable = entry.is_executable!()?
							$files = $files.append({ relative, executable })
						}
						IsSymLink => return Err(Snapshot.refused(Symlink, entry))
						IsOther => return Err(Snapshot.refused(Special, entry))
					}
				}
			}
		}
		Snapshot.copy_files!(source_root, target_root, $files)
	}

	refused = |kind, path|
		match kind {
			Symlink => SnapshotFailed("snapshot refuses symlink: ${path.display()}")
			Special =>
				SnapshotFailed("snapshot refuses special file: ${path.display()}")
			}

	# basic-cli cannot open without following links or set file modes, so GNU
	# cp copies with O_NOFOLLOW (a file swapped for a link or special file is
	# copied as one, then refused below) and chmod normalizes modes as 755/644.
	copy_files! = |source_root, target_root, files| {
		for batch in Snapshot.batches(files) {
			Snapshot.tool!(
				"cp",
				["-R", "-P", "--parents", "--"],
				batch.map(|file| file.relative).append(target_root),
				source_root,
			)?
		}
		for file in files {
			copied = Path.unix_bytes(Snapshot.join(target_root, file.relative))
			original = Path.unix_bytes(Snapshot.join(source_root, file.relative))
			match copied.type!()? {
				IsFile => {}
				IsSymLink => return Err(Snapshot.refused(Symlink, original))
				_ => return Err(Snapshot.refused(Special, original))
			}
		}
		for (mode, executable) in [("0755", Bool.True), ("0644", Bool.False)] {
			chosen = files.keep_if(|file| file.executable == executable)
			for batch in Snapshot.batches(chosen) {
				Snapshot.tool!(
					"chmod",
					[mode, "--"],
					batch.map(|file| file.relative),
					target_root,
				)?
			}
		}
		Ok({})
	}

	tool! = |program, flags, operands, cwd| {
		_ = Cmd.new_str(program)
			.args_str(flags)
			.args(operands.map(OsStr.unix_bytes))
			.cwd(Path.unix_bytes(cwd))
			.exec_output!()
			.map_err(
				|err|
					match err {
						NonZeroExitCode({ stderr_utf8_lossy, .. }) =>
							SnapshotFailed("${program} failed: ${stderr_utf8_lossy.trim()}")
						_ => SnapshotFailed("${program} failed: ${Str.inspect(err)}")
					},
			)?
		Ok({})
	}
}

# Names match basenames at any depth; absolute paths exclude whole trees.
expect match Snapshot.filter([".git", "/p/.kai", "/p/assets"]) {
	Ok(exclusions) =>
		[
			("/p/.git", ".git", Bool.True),
			("/p/src/.git", ".git", Bool.True),
			("/p/.kai", ".kai", Bool.True),
			("/p/.kai/snapshot", "snapshot", Bool.True),
			("/p/assets", "assets", Bool.True),
			("/p/assets2", "assets2", Bool.False),
			("/p/src/assets", "assets", Bool.False),
			("/p/.gitignore", ".gitignore", Bool.False),
		].all(
			|(entry, name, expected)|
				Snapshot.excluded(exclusions, entry.to_utf8(), name.to_utf8())
					== expected,
		)
	Err(_) => Bool.False
}

# An exclusion is one name or an absolute path, never a relative path.
expect [["a/b"], [""], ["."], [".."]]
	.all(|items| Snapshot.filter(items).is_err())

# The snapshot may not contain the project, and inside it needs an excluded
# parent so it never copies itself.
expect {
	exclusions = { names: [], paths: ["/p/.kai".to_utf8()] }
	[
		("/p", "/p/.kai/snapshot", Ok({})),
		("/p", "/work/snapshot", Ok({})),
		("/p", "/p/snapshot", Err("in-tree snapshot parent must be excluded")),
		("/p/src", "/p", Err("snapshot destination must not contain the project")),
		("/p", "/p", Err("snapshot destination must not contain the project")),
	].all(
		|(root, destination, expected)|
			Snapshot.check(root, destination, exclusions) == expected,
	)
}

# Containment is by whole components, and everything is within the root.
expect [
	("/p", "/p", Bool.True),
	("/p", "/p/a", Bool.True),
	("/p", "/pa", Bool.False),
	("/p/a", "/p", Bool.False),
	("/", "/p", Bool.True),
].all(
	|(parent, child, expected)|
		Snapshot.within(parent.to_utf8(), child.to_utf8()) == expected,
)

# Only well-formed namespace identities become the isolation witness.
expect [
	("mnt", "mnt:[4026531841]", Ok("mnt:[4026531841]")),
	("net", "mnt:[4026531841]", Err("invalid caller net namespace identity")),
	("mnt", "mnt:[]", Err("invalid caller mnt namespace identity")),
	("mnt", "mnt:[12a]", Err("invalid caller mnt namespace identity")),
	("mnt", "mnt:[1]]", Err("invalid caller mnt namespace identity")),
].all(
	|(name, observed, expected)|
		Snapshot.identity(name, observed) == expected,
)

# The witness is sorted JSON, byte-identical across snapshots of one caller.
expect Snapshot.witness_json("mnt:[1]", "net:[2]")
	== "{\"mnt\": \"mnt:[1]\", \"net\": \"net:[2]\"}\n"

# Copy and chmod argument lists are bounded.
expect {
	sizes = Snapshot.batches(List.repeat(0, 600)).map(List.len)
	sizes == [256, 256, 88] and Snapshot.batches([]).is_empty()
}

# Relative entries join without a leading or trailing separator.
expect [("", "a", "a"), ("a", "", "a"), ("/p", "a/b", "/p/a/b")].all(
	|(base, relative, joined)|
		Snapshot.join(base.to_utf8(), relative.to_utf8()) == joined.to_utf8(),
)
