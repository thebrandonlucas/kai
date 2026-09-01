# Prepare the generated xkai source tree and embedded source archive.
import pf.Cmd
import pf.OsStr
import pf.Path

PrepareXkai := [].{
	archive_suffix = ".tar.zst"
	hash_alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

	run! = |bundle_dir, source_dir, output_dir| {
		bundle_root = Path.utf8(bundle_dir)
		source_root = Path.utf8(source_dir)
		output_root = Path.utf8(output_dir)
		archive = PrepareXkai.find_archive!(bundle_root)?
		archive_name = PrepareXkai.filename(archive)?
		xkai_source = Path.join(source_root, "xkai")
		PrepareXkai.require_dir!(xkai_source, "xkai")?
		PrepareXkai.validate_tree!(source_root)?
		Path.create_all!(output_root)?
		# TODO: Use basic-cli Path copying after Roc's folded Path dispatch bug
		# is fixed.
		PrepareXkai.copy_dir!(Path.join(source_root, "."), output_root)?
		PrepareXkai.copy_file!(
			archive,
			Path.join(Path.join(output_root, "xkai"), archive_name),
		)?
		hash = Str.from_utf8_lossy(
			Str.to_utf8(archive_name).drop_last(
				Str.to_utf8(PrepareXkai.archive_suffix).len(),
			),
		)
		Path.write_utf8!(
			Path.join(Path.join(output_root, "xkai"), "EmbeddedSources.roc"),
			PrepareXkai.render_module(archive_name, hash),
		)
	}

	require_dir! = |path, relative| {
		is_directory = Path.is_dir!(path) ? |_| MissingSourceRoot(relative)
		if is_directory Ok({}) else Err(MissingSourceRoot(relative))
	}

	find_archive! = |bundle_root| {
		archives = PrepareXkai.archive_files!(Path.list!(bundle_root)?)?
		match archives {
			[archive] => {
				name = PrepareXkai.filename(archive)?
				hash = Str.from_utf8_lossy(
					Str.to_utf8(name).drop_last(
						Str.to_utf8(PrepareXkai.archive_suffix).len(),
					),
				)
				if PrepareXkai.hash_is_valid(hash) {
					Ok(archive)
				} else {
					Err(InvalidContentHash(hash))
				}
			}
			[] => Err(MissingArchive)
			_ => Err(MultipleArchives)
		}
	}

	archive_files! = |entries|
		match entries {
			[] => Ok([])
			[first, .. as rest] => {
				remaining = PrepareXkai.archive_files!(rest)?
				if Path.is_file!(first)? {
					name = PrepareXkai.filename(first)?
					if name.ends_with(PrepareXkai.archive_suffix) {
						Ok([first].concat(remaining))
					} else {
						Ok(remaining)
					}
				} else {
					Ok(remaining)
				}
			}
		}

	hash_is_valid = |hash| {
		bytes = Str.to_utf8(hash)
		alphabet = Str.to_utf8(PrepareXkai.hash_alphabet)
		bytes.len() >= 32 and
			bytes.len() <= 44 and
				List.all(bytes, |byte| alphabet.contains(byte))
	}

	filename = |path| {
		name = Path.filename(path) ? |_| InvalidSourcePath(Path.display(path))
		text = Path.to_str(name) ? |_| InvalidSourcePath(Path.display(path))
		Ok(text)
	}

	validate_tree! = |root|
		PrepareXkai.validate_entries!(Path.list!(root)?)

	validate_entries! = |entries|
		match entries {
			[] => Ok({})
			[first, .. as rest] => {
				if Path.is_dir!(first)? {
					PrepareXkai.validate_tree!(first)?
				} else if !Path.is_file!(first)? {
					return Err(UnsupportedSourceEntry(Path.display(first)))
				}
				PrepareXkai.validate_entries!(rest)
			}
		}

	copy_dir! = |source, destination|
		Cmd.exec!(
			OsStr.utf8("cp"),
			[
				OsStr.utf8("-R"),
				OsStr.utf8("--"),
				Path.to_os_str(source),
				Path.to_os_str(destination),
			],
		)

	copy_file! = |source, destination|
		Cmd.exec!(
			OsStr.utf8("cp"),
			[
				OsStr.utf8("--"),
				Path.to_os_str(source),
				Path.to_os_str(destination),
			],
		)

	render_module = |archive_name, hash|
		Str.join_with(
			[
				"import \"${archive_name}\" as archive_bytes : List(U8)",
				"",
				"EmbeddedSources := [].{",
				"    archive = {",
				"        bytes: archive_bytes,",
				"        filename: \"${archive_name}\",",
				"        root: \"${hash}\",",
				"    }",
				"}",
				"",
			],
			"\n",
		)
}
