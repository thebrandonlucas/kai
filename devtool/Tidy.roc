# Invariants that should always be true about the code to maintain conceptual
# integrity.
#
# Currently there are 2:
# - Enforce each code module to have a top-level explainer comment
# - Limit line length to 80
#
# Inspired by [tidy.zig]
import pf.Path
import pf.Stderr

Tidy := [].{
	Violation := {
		kind : [LineTooLong(U64), MissingModuleComment],
		line : U64,
	}

	Diagnostic := {
		kind : [LineTooLong(U64), MissingModuleComment],
		line : U64,
		path : Str,
	}

	excluded_directories = [
		".direnv",
		".git",
		".kai",
		".zig-cache",
		"dist",
		"fuzz",
		"zig-out",
	]

	line_limit : U64
	line_limit = 80

	ansi_escape = Str.from_utf8_lossy([27])
	ansi_red = "${Tidy.ansi_escape}[31m"
	ansi_green = "${Tidy.ansi_escape}[32m"
	ansi_reset = "${Tidy.ansi_escape}[0m"

	colorize = |color, text| "${color}${text}${Tidy.ansi_reset}"

	codepoint_count : Str -> U64
	codepoint_count = |line|
		Str.to_utf8(line).fold(
			0,
			|count, byte|
				if byte < 0x80 or byte >= 0xC0 {
					count + 1
				} else {
					count
				},
		)

	indexed_lines = |source|
		source.split_on("\n").map_with_index(
			|text, index| {
				line: index + 1,
				text,
			},
		)

	is_comment = |line| line.trim().starts_with("#")

	has_module_comment = |line|
		(line.starts_with("# ") and line.trim() != "#") or
			(line.starts_with("## ") and line.trim() != "##")

	is_package_declaration = |line| {
		trimmed = line.trim()
		trimmed == "package" or trimmed.starts_with("package ")
	}

	comment_violations = |lines| {
		first_code = lines.keep_if(
			|line| {
				trimmed = line.text.trim()
				!trimmed.is_empty() and !Tidy.is_comment(trimmed)
			},
		).first()
		first_line = lines.first()

		match (first_code, first_line) {
			(Ok(code), Ok(_)) if Tidy.is_package_declaration(code.text) => []
			(Ok(_), Ok(top)) if Tidy.has_module_comment(top.text) => []
			(Ok(_), Ok(top)) => [{ kind: MissingModuleComment, line: top.line }]
			_ => []
		}
	}

	line_violations = |lines|
		lines.map(
			|line| {
				line: line.line,
				width: Tidy.codepoint_count(line.text),
			},
		).keep_if(|line| line.width > Tidy.line_limit).map(
			|line| {
				kind: LineTooLong(line.width),
				line: line.line,
			},
		)

	check_file : Str -> List(Violation)
	check_file = |source| {
		lines = Tidy.indexed_lines(source)
		Tidy.comment_violations(lines).concat(Tidy.line_violations(lines))
	}

	discover! = |path| {
		if Path.is_sym_link!(path)? {
			Ok([])
		} else if Path.is_dir!(path)? {
			name = Path.display(Path.filename(path) ?? path)
			if Tidy.excluded_directories.contains(name) {
				Ok([])
			} else {
				Tidy.discover_entries!(Path.list!(path)?)
			}
		} else if
			Path.is_file!(path)? and
				Path.display(Path.filename(path) ?? path).ends_with(".roc")
				{
					Ok([path])
				} else {
					Ok([])
				}
	}

	discover_entries! = |entries|
		match entries {
			[] => Ok([])
			[first, .. as rest] => {
				found = Tidy.discover!(first)?
				remaining = Tidy.discover_entries!(rest)?
				Ok(found.concat(remaining))
			}
		}

	check_paths! = |paths|
		match paths {
			[] => Ok([])
			[path, .. as rest] => {
				raw_path = Path.display(path)
				display_path = if raw_path.starts_with("./") {
					Str.from_utf8_lossy(raw_path.to_utf8().drop_first(2))
				} else {
					raw_path
				}
				source = Path.read_utf8!(path)?
				diagnostics = Tidy.check_file(source).map(
					|violation| {
						kind: violation.kind,
						line: violation.line,
						path: display_path,
					},
				)
				remaining = Tidy.check_paths!(rest)?
				Ok(diagnostics.concat(remaining))
			}
		}

	print_check! = |label, passed| {
		color = if passed Tidy.ansi_green else Tidy.ansi_red
		status = if passed "PASS" else "FAIL"
		Stderr.line!(Tidy.colorize(color, "  ${status}  ${label}"))
	}

	print_report! = |diagnostics| {
		missing_comments = diagnostics.keep_if(
			|diagnostic|
				match diagnostic.kind {
					MissingModuleComment => Bool.True
					LineTooLong(_) => Bool.False
				},
		)
		long_lines = diagnostics.keep_if(
			|diagnostic|
				match diagnostic.kind {
					MissingModuleComment => Bool.False
					LineTooLong(_) => Bool.True
				},
		)

		if !missing_comments.is_empty() {
			header = "Missing module comments (${
				U64.to_str(missing_comments.len())
			}):"
			Stderr.line!(Tidy.colorize(Tidy.ansi_red, header))?
			for diagnostic in missing_comments {
				line = U64.to_str(diagnostic.line)
				Stderr.line!("  ${diagnostic.path}:${line}")?
			}
		}
		if !long_lines.is_empty() {
			if !missing_comments.is_empty() {
				Stderr.line!("")?
			}
			header = "Lines over 80 codepoints (${
				U64.to_str(long_lines.len())
			}):"
			Stderr.line!(Tidy.colorize(Tidy.ansi_red, header))?
			for diagnostic in long_lines {
				line = U64.to_str(diagnostic.line)
				width = match diagnostic.kind {
					LineTooLong(found) => found
					MissingModuleComment => 0
				}
				Stderr.line!(
					"  ${diagnostic.path}:${line} (${U64.to_str(width)} codepoints)",
				)?
			}
		}
		if !diagnostics.is_empty() {
			Stderr.line!("")?
		}
		Stderr.line!("Checks:")?
		Tidy.print_check!("Module comments", missing_comments.is_empty())?
		Tidy.print_check!("80-codepoint line limit", long_lines.is_empty())?

		count = diagnostics.len()
		label = if count == 1 "violation" else "violations"
		total = "Total: ${U64.to_str(count)} ${label}"
		color = if diagnostics.is_empty() Tidy.ansi_green else Tidy.ansi_red
		Stderr.line!(Tidy.colorize(color, total))
	}

	run! = |paths| {
		roc_files = if paths.is_empty() {
			Tidy.discover!(Path.utf8("."))?
		} else {
			paths.map(Path.utf8)
		}
		diagnostics = Tidy.check_paths!(roc_files)?
		Tidy.print_report!(diagnostics)?
		if diagnostics.is_empty() {
			Ok({})
		} else {
			Err(Exit(1))
		}
	}
}
