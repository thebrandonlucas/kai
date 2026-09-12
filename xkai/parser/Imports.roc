# Recognize standalone Kaifile import directives without performing effects.
Imports := [].{
	ImportLine : [ImportPath(Str), InvalidImport, NotImport]

	parse_import_line : Str -> ImportLine
	parse_import_line = |source_line| {
		trimmed_line = source_line.trim()
		if trimmed_line == "import" {
			InvalidImport
		} else if !trimmed_line.starts_with("import ") {
			NotImport
		} else if !trimmed_line.starts_with("import \"") {
			InvalidImport
		} else {
			quoted_path = Str.from_utf8_lossy(trimmed_line.to_utf8().drop_first(7))
			match Json.parse(quoted_path) {
				Ok(import_path) if !import_path.is_empty() => ImportPath(import_path)
				_ => InvalidImport
			}
		}
	}
}
