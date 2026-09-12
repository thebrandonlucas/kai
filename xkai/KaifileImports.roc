# Load Kaifiles and recursively compose local imports.
import pf.Path
import parser.Imports

KaifileImports := [].{
	# Normalize "." and ".." so equivalent import paths compare equally even if
	# they weren't written equally.
	#
	# Example:
	# - ./foo → foo
	# - dir/./foo → dir/foo
	# - dir/../foo → foo
	#
	# Symbolic links remain unresolved.
	normalize_path_segments = |remaining_segments, normalized_segments| {
		can_remove_parent = normalized_segments != [""] and
			(normalized_segments.last() ?? "..") != ".."
		match remaining_segments {
			[] => normalized_segments
			# The first empty segment preserves the root of an absolute path.
			["", .. as rest] if normalized_segments.is_empty() =>
				KaifileImports.normalize_path_segments(rest, [""])
			["", .. as rest] | [".", .. as rest] =>
				KaifileImports.normalize_path_segments(rest, normalized_segments)
			["..", .. as rest] if can_remove_parent =>
				KaifileImports.normalize_path_segments(
					rest,
					normalized_segments.drop_last(1),
				)
			[first, .. as rest] =>
				KaifileImports.normalize_path_segments(
					rest,
					normalized_segments.append(first),
				)
			}
	}

	# i.e. normalize it to it's lexical meaning even if it's represented
	# differently.
	lexically_normalize_path = |path|
		Str.join_with(
			KaifileImports.normalize_path_segments(path.split_on("/"), []),
			"/",
		)

	resolve_import_path = |source_path, import_path| {
		importing_directory = Str.join_with(
			source_path.split_on("/").drop_last(1),
			"/",
		)
		import_base_directory =
			if importing_directory.is_empty() and source_path.starts_with("/") {
				"/"
			} else {
				importing_directory
			}
		resolved_path = if import_base_directory.is_empty() {
			import_path
		} else {
			"${import_base_directory}/${import_path}"
		}
		KaifileImports.lexically_normalize_path(resolved_path)
	}

	# Load a Kaifile, replacing import lines with files resolved relative to it.
	# Active import paths are retained only to reject recursive import cycles.
	load_expanded_kaifile! = |source_path, active_import_paths| {
		normalized_source_path = KaifileImports.lexically_normalize_path(source_path)
		if active_import_paths.contains(normalized_source_path) {
			Err(ImportCycle(active_import_paths.append(normalized_source_path)))
		} else {
			source_text = Path.read_utf8!(Path.utf8(normalized_source_path))?
			expanded_lines = source_text.split_on("\n").map_try(
				|source_line|
					match Imports.parse_import_line(source_line) {
						NotImport => Ok(source_line)
						InvalidImport => Err(
							InvalidImportLine({ path: normalized_source_path, source_line }),
						)
						ImportPath(import_path) => {
							imported_path = KaifileImports.resolve_import_path(
								normalized_source_path,
								import_path,
							)
							KaifileImports.load_expanded_kaifile!(
								imported_path,
								active_import_paths.append(normalized_source_path),
							)
						}
					},
			)?
			Ok(Str.join_with(expanded_lines, "\n"))
		}
	}

	load! : Str => Try(Str, _)
	load! = |source_path| KaifileImports.load_expanded_kaifile!(source_path, [])
}
