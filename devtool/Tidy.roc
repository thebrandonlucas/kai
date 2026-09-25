# Invariants that should always be true about the code to maintain conceptual
# integrity.
#
# Currently there are 6:
# - Enforce each code module and expect test to have an explainer comment
# - Require every backend planner to have executed planning expect tests
# - Limit line length to 80
# - Reject direct static literal-list Str.join_with calls
# - Require character literals in ASCII byte comparisons
#
# Inspired by [tidy.zig]
import pf.Path
import pf.Stderr

Tidy := [].{
	Kind : [
		LineTooLong(U64),
		MissingExpectComment,
		MissingImplementationTest(Str),
		MissingModuleComment,
		NumericAsciiByteComparison,
		StaticLiteralJoin,
	]

	Violation := { kind : Kind, line : U64 }
	Diagnostic := { kind : Kind, line : U64, path : Str }
	Planner : { path : Str, root : Str, tested : Bool }

	excluded_directories = [
		".direnv",
		".git",
		".kai",
		".zig-cache",
		"dist",
		"zig-out",
	]

	line_limit : U64
	line_limit = 80

	static_join_name = "Str.join_with".to_utf8()

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

	# `roc fmt` keeps these platform header entries on one line.
	is_platform_header_line = |line| {
		trimmed = line.trim()
		trimmed.starts_with("pf: platform \"") or trimmed.contains(": { inputs: [")
	}

	has_module_comment = |line|
		(line.starts_with("# ") and line.trim() != "#") or
			(line.starts_with("## ") and line.trim() != "##")

	is_package_declaration = |line| {
		trimmed = line.trim()
		trimmed == "package" or trimmed.starts_with("package ")
	}

	is_expect = |line| {
		trimmed = line.trim()
		trimmed == "expect" or trimmed.starts_with("expect ")
	}

	expect_comment_violations = |lines, previous|
		match lines {
			[] => []
			[first, .. as rest] => {
				trimmed = first.text.trim()
				current = if trimmed.is_empty() previous else trimmed
				violation = if Tidy.is_expect(trimmed) and
					!Tidy.has_module_comment(previous) {
					[{ kind: MissingExpectComment, line: first.line }]
				} else {
					[]
				}
				violation.concat(Tidy.expect_comment_violations(rest, current))
			}
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
				text: line.text,
				width: Tidy.codepoint_count(line.text),
			},
		).keep_if(
			|line|
				line.width > Tidy.line_limit and
					!Tidy.is_platform_header_line(line.text),
		).map(
			|line| {
				kind: LineTooLong(line.width),
				line: line.line,
			},
		)

	byte_at = |bytes, index| bytes.get(index) ?? 0

	is_whitespace = |byte|
		byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r'

	skip_comment = |bytes, index|
		if index >= bytes.len() or Tidy.byte_at(bytes, index) == '\n' {
			index
		} else {
			Tidy.skip_comment(bytes, index + 1)
		}

	skip_trivia = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Tidy.byte_at(bytes, index)
			if Tidy.is_whitespace(byte) {
				Tidy.skip_trivia(bytes, index + 1)
			} else if byte == '#' {
				Tidy.skip_trivia(bytes, Tidy.skip_comment(bytes, index))
			} else {
				index
			}
		}

	bytes_match = |bytes, index, expected, expected_index|
		if expected_index >= expected.len() {
			Bool.True
		} else if
			index >= bytes.len() or
				Tidy.byte_at(bytes, index) != Tidy.byte_at(expected, expected_index)
				{
					Bool.False
				} else {
					Tidy.bytes_match(bytes, index + 1, expected, expected_index + 1)
				}

	is_identifier_byte = |byte|
		(byte >= 'a' and byte <= 'z') or
			(byte >= 'A' and byte <= 'Z') or
				(byte >= '0' and byte <= '9') or
					byte == '_' or
						byte == '.'

	has_static_join_name = |bytes, index|
		(index == 0 or !Tidy.is_identifier_byte(Tidy.byte_at(bytes, index - 1))) and
			Tidy.bytes_match(bytes, index, Tidy.static_join_name, 0)

	identifier_end = |bytes, index|
		if
			index < bytes.len() and
				Tidy.is_identifier_byte(Tidy.byte_at(bytes, index))
				{
					Tidy.identifier_end(bytes, index + 1)
				} else {
					index
				}

	is_byte_identifier = |bytes, start, end| {
		identifier = Str.from_utf8_lossy(
			bytes.sublist({ start, len: end - start }),
		)
		identifier == "byte" or identifier.ends_with("_byte")
	}

	comparison_end = |bytes, raw_index| {
		index = Tidy.skip_trivia(bytes, raw_index)
		first = Tidy.byte_at(bytes, index)
		second = Tidy.byte_at(bytes, index + 1)
		if
			(first == '<' or first == '>') and second == '=' or
				((first == '=' or first == '!') and second == '=')
				{
					ComparisonEnd(index + 2)
				} else if first == '<' or first == '>' {
					ComparisonEnd(index + 1)
				} else {
					NoComparison
				}
	}

	digit_value : U8 -> [Digit(U8), NotDigit]
	digit_value = |byte|
		if byte >= '0' and byte <= '9' {
			Digit(byte - '0')
		} else if byte >= 'a' and byte <= 'f' {
			Digit(byte - 'a' + 10)
		} else if byte >= 'A' and byte <= 'F' {
			Digit(byte - 'A' + 10)
		} else {
			NotDigit
		}

	ascii_digits_end = |bytes, index, radix, value, found_digit|
		if Tidy.byte_at(bytes, index) == '_' and found_digit {
			Tidy.ascii_digits_end(bytes, index + 1, radix, value, found_digit)
		} else {
			match Tidy.digit_value(Tidy.byte_at(bytes, index)) {
				Digit(digit) if digit < radix =>
					if value > (127 - digit) / radix {
						NotAsciiNumber
					} else {
						Tidy.ascii_digits_end(
							bytes,
							index + 1,
							radix,
							value * radix + digit,
							Bool.True,
						)
					}
				_ => if found_digit and value != 0 {
					AsciiNumberEnd(index)
				} else {
					NotAsciiNumber
				}
			}
		}

	ascii_number_end = |bytes, index|
		if Tidy.byte_at(bytes, index) == '0' {
			prefix = Tidy.byte_at(bytes, index + 1)
			if prefix == 'b' or prefix == 'B' {
				Tidy.ascii_digits_end(bytes, index + 2, 2, 0, Bool.False)
			} else if prefix == 'o' or prefix == 'O' {
				Tidy.ascii_digits_end(bytes, index + 2, 8, 0, Bool.False)
			} else if prefix == 'x' or prefix == 'X' {
				Tidy.ascii_digits_end(bytes, index + 2, 16, 0, Bool.False)
			} else {
				Tidy.ascii_digits_end(bytes, index, 10, 0, Bool.False)
			}
		} else {
			Tidy.ascii_digits_end(bytes, index, 10, 0, Bool.False)
		}

	is_numeric_ascii_byte_comparison = |bytes, index| {
		at_boundary = index == 0 or
			!Tidy.is_identifier_byte(Tidy.byte_at(bytes, index - 1))
		left_end = Tidy.identifier_end(bytes, index)
		left_byte = at_boundary and left_end > index and
			Tidy.is_byte_identifier(bytes, index, left_end)
		left_violation = if left_byte {
			match Tidy.comparison_end(bytes, left_end) {
				NoComparison => Bool.False
				ComparisonEnd(after_comparison) => {
					number = Tidy.skip_trivia(bytes, after_comparison)
					match Tidy.ascii_number_end(bytes, number) {
						AsciiNumberEnd(_) => Bool.True
						NotAsciiNumber => Bool.False
					}
				}
			}
		} else {
			Bool.False
		}
		if left_violation {
			Bool.True
		} else if at_boundary {
			match Tidy.ascii_number_end(bytes, index) {
				NotAsciiNumber => Bool.False
				AsciiNumberEnd(number_end) =>
					match Tidy.comparison_end(bytes, number_end) {
						NoComparison => Bool.False
						ComparisonEnd(after_comparison) => {
							identifier = Tidy.skip_trivia(bytes, after_comparison)
							end = Tidy.identifier_end(bytes, identifier)
							end > identifier and
								Tidy.is_byte_identifier(bytes, identifier, end)
						}
					}
				}
		} else {
			Bool.False
		}
	}

	string_end = |bytes, index|
		if index >= bytes.len() or Tidy.byte_at(bytes, index) == '\n' {
			index
		} else if Tidy.byte_at(bytes, index) == '"' {
			index + 1
		} else if Tidy.byte_at(bytes, index) == '\\' {
			Tidy.string_end(bytes, index + 2)
		} else {
			Tidy.string_end(bytes, index + 1)
		}

	static_string_end = |bytes, index|
		if index >= bytes.len() {
			NotStatic
		} else {
			byte = Tidy.byte_at(bytes, index)
			if byte == '"' {
				StaticEnd(index + 1)
			} else if byte == '\n' {
				NotStatic
			} else if byte == '\\' {
				Tidy.static_string_end(bytes, index + 2)
			} else if byte == '$' and Tidy.byte_at(bytes, index + 1) == '{' {
				NotStatic
			} else {
				Tidy.static_string_end(bytes, index + 1)
			}
		}

	skip_indentation = |bytes, index|
		if
			Tidy.byte_at(bytes, index) == ' ' or
				Tidy.byte_at(bytes, index) == '\t'
				{
					Tidy.skip_indentation(bytes, index + 1)
				} else {
					index
				}

	static_line_string_end = |bytes, index|
		if index >= bytes.len() {
			StaticEnd(index)
		} else {
			byte = Tidy.byte_at(bytes, index)
			if byte == '\n' {
				next = Tidy.skip_indentation(bytes, index + 1)
				if
					Tidy.byte_at(bytes, next) == '\\' and
						Tidy.byte_at(bytes, next + 1) == '\\'
						{
							Tidy.static_line_string_end(bytes, next + 2)
						} else {
							StaticEnd(index)
						}
			} else if byte == '\\' {
				Tidy.static_line_string_end(bytes, index + 2)
			} else if byte == '$' and Tidy.byte_at(bytes, index + 1) == '{' {
				NotStatic
			} else {
				Tidy.static_line_string_end(bytes, index + 1)
			}
		}

	static_literal_end = |bytes, index|
		if Tidy.byte_at(bytes, index) == '"' {
			Tidy.static_string_end(bytes, index + 1)
		} else if
			Tidy.byte_at(bytes, index) == '\\' and
				Tidy.byte_at(bytes, index + 1) == '\\'
				{
					Tidy.static_line_string_end(bytes, index + 2)
				} else {
					NotStatic
				}

	static_list_end = |bytes, raw_index, count| {
		index = Tidy.skip_trivia(bytes, raw_index)
		match Tidy.static_literal_end(bytes, index) {
			NotStatic => NotStatic
			StaticEnd(end_index) => {
				after_string = Tidy.skip_trivia(bytes, end_index)
				next_count = count + 1
				if Tidy.byte_at(bytes, after_string) == ']' {
					StaticEnd({ count: next_count, index: after_string + 1 })
				} else if Tidy.byte_at(bytes, after_string) != ',' {
					NotStatic
				} else {
					after_comma = Tidy.skip_trivia(bytes, after_string + 1)
					if Tidy.byte_at(bytes, after_comma) == ']' {
						StaticEnd({ count: next_count, index: after_comma + 1 })
					} else {
						Tidy.static_list_end(bytes, after_comma, next_count)
					}
				}
			}
		}
	}

	is_static_join = |bytes, start| {
		after_name = Tidy.skip_trivia(bytes, start + Tidy.static_join_name.len())
		if Tidy.byte_at(bytes, after_name) != '(' {
			Bool.False
		} else {
			list_start = Tidy.skip_trivia(bytes, after_name + 1)
			if Tidy.byte_at(bytes, list_start) != '[' {
				Bool.False
			} else {
				match Tidy.static_list_end(bytes, list_start + 1, 0) {
					NotStatic => Bool.False
					StaticEnd(list) => {
						after_list = Tidy.skip_trivia(bytes, list.index)
						if
							list.count < 2 or
								Tidy.byte_at(bytes, after_list) != ','
								{
									Bool.False
								} else {
									separator = Tidy.skip_trivia(bytes, after_list + 1)
									match Tidy.static_literal_end(bytes, separator) {
										NotStatic => Bool.False
										StaticEnd(separator_end) => {
											after_separator = Tidy.skip_trivia(
												bytes,
												separator_end,
											)
											closing = if
												Tidy.byte_at(bytes, after_separator) == ','
													{
														Tidy.skip_trivia(bytes, after_separator + 1)
													} else {
														after_separator
													}
											Tidy.byte_at(bytes, closing) == ')'
										}
									}
								}
					}
				}
			}
		}
	}

	char_end = |bytes, index|
		if index >= bytes.len() or Tidy.byte_at(bytes, index) == '\n' {
			index
		} else if Tidy.byte_at(bytes, index) == '\'' {
			index + 1
		} else if Tidy.byte_at(bytes, index) == '\\' {
			Tidy.char_end(bytes, index + 2)
		} else {
			Tidy.char_end(bytes, index + 1)
		}

	interpolation_end = |bytes, index, depth, limit|
		if index >= limit {
			limit
		} else {
			byte = Tidy.byte_at(bytes, index)
			if byte == '"' {
				Tidy.interpolation_end(
					bytes,
					Tidy.string_end(bytes, index + 1),
					depth,
					limit,
				)
			} else if byte == '\'' {
				Tidy.interpolation_end(
					bytes,
					Tidy.char_end(bytes, index + 1),
					depth,
					limit,
				)
			} else if byte == '#' {
				Tidy.interpolation_end(
					bytes,
					Tidy.skip_comment(bytes, index),
					depth,
					limit,
				)
			} else if byte == '\\' and Tidy.byte_at(bytes, index + 1) == '\\' {
				Tidy.interpolation_end(
					bytes,
					Tidy.skip_comment(bytes, index),
					depth,
					limit,
				)
			} else if byte == '{' {
				Tidy.interpolation_end(bytes, index + 1, depth + 1, limit)
			} else if byte == '}' and depth == 1 {
				index
			} else if byte == '}' {
				Tidy.interpolation_end(bytes, index + 1, depth - 1, limit)
			} else {
				Tidy.interpolation_end(bytes, index + 1, depth, limit)
			}
		}

	line_through = |bytes, index, end, line|
		if index >= end {
			line
		} else {
			next_line = if Tidy.byte_at(bytes, index) == '\n' line + 1 else line
			Tidy.line_through(bytes, index + 1, end, next_line)
		}

	scan_string = |bytes, index, line, violations, limit|
		if index >= limit {
			violations
		} else {
			byte = Tidy.byte_at(bytes, index)
			if byte == '"' or byte == '\n' {
				Tidy.scan_static_joins(bytes, index + 1, line, violations, limit)
			} else if byte == '\\' {
				Tidy.scan_string(bytes, index + 2, line, violations, limit)
			} else if byte == '$' and Tidy.byte_at(bytes, index + 1) == '{' {
				closing = Tidy.interpolation_end(bytes, index + 2, 1, limit)
				found = Tidy.scan_static_joins(
					bytes,
					index + 2,
					line,
					violations,
					closing,
				)
				next_line = Tidy.line_through(bytes, index + 2, closing, line)
				Tidy.scan_string(bytes, closing + 1, next_line, found, limit)
			} else {
				Tidy.scan_string(bytes, index + 1, line, violations, limit)
			}
		}

	scan_line_string = |bytes, index, line, violations, limit|
		if index >= limit {
			violations
		} else {
			byte = Tidy.byte_at(bytes, index)
			if byte == '\n' {
				Tidy.scan_static_joins(bytes, index, line, violations, limit)
			} else if byte == '\\' {
				Tidy.scan_line_string(bytes, index + 2, line, violations, limit)
			} else if byte == '$' and Tidy.byte_at(bytes, index + 1) == '{' {
				closing = Tidy.interpolation_end(bytes, index + 2, 1, limit)
				found = Tidy.scan_static_joins(
					bytes,
					index + 2,
					line,
					violations,
					closing,
				)
				next_line = Tidy.line_through(bytes, index + 2, closing, line)
				Tidy.scan_line_string(bytes, closing + 1, next_line, found, limit)
			} else {
				Tidy.scan_line_string(bytes, index + 1, line, violations, limit)
			}
		}

	scan_static_joins = |bytes, index, line, violations, limit|
		if index >= limit {
			violations
		} else {
			byte = Tidy.byte_at(bytes, index)
			if byte == '"' {
				Tidy.scan_string(bytes, index + 1, line, violations, limit)
			} else if byte == '\'' {
				Tidy.scan_static_joins(
					bytes,
					Tidy.char_end(bytes, index + 1),
					line,
					violations,
					limit,
				)
			} else if byte == '#' {
				Tidy.scan_static_joins(
					bytes,
					Tidy.skip_comment(bytes, index),
					line,
					violations,
					limit,
				)
			} else if byte == '\\' and Tidy.byte_at(bytes, index + 1) == '\\' {
				Tidy.scan_line_string(bytes, index + 2, line, violations, limit)
			} else if Tidy.is_numeric_ascii_byte_comparison(bytes, index) {
				Tidy.scan_static_joins(
					bytes,
					index + 1,
					line,
					violations.append({
						kind: NumericAsciiByteComparison,
						line,
					}),
					limit,
				)
			} else if
				Tidy.has_static_join_name(bytes, index) and
					Tidy.is_static_join(bytes, index)
					{
						Tidy.scan_static_joins(
							bytes,
							index + Tidy.static_join_name.len(),
							line,
							violations.append({ kind: StaticLiteralJoin, line }),
							limit,
						)
					} else {
						next_line = if byte == '\n' line + 1 else line
						Tidy.scan_static_joins(
							bytes,
							index + 1,
							next_line,
							violations,
							limit,
						)
					}
		}

	static_join_violations = |source| {
		bytes = source.to_utf8()
		Tidy.scan_static_joins(bytes, 0, 1, [], bytes.len())
	}

	check_file : Str -> List(Violation)
	check_file = |source| {
		lines = Tidy.indexed_lines(source)
		Tidy.comment_violations(lines)
			.concat(Tidy.expect_comment_violations(lines, ""))
			.concat(Tidy.line_violations(lines))
			.concat(Tidy.static_join_violations(source))
	}

	# Annotated to avoid a compiler hang:
	# https://github.com/roc-lang/roc/issues/11621
	# Remove this workaround once the Roc pin includes the fix.
	discover! : Path => Try(List(Path), _)
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

	# Backend planners take the IR and a request; `plan : Ir, Request, ...`.
	is_planner = |source|
		List.any(
			Tidy.indexed_lines(source),
			|line| line.text.starts_with("\tplan : Ir, Request"),
		)

	relative_path = |raw_path|
		if raw_path.starts_with("./") {
			Str.from_utf8_lossy(raw_path.to_utf8().drop_first(2))
		} else {
			raw_path
		}

	# A planner is tested when its own expects call it and its package root,
	# which must expose it, is a `roc test` root in build.zig.
	planner_tested! = |path, source, build_source| {
		parts = path.split_on("/")
		stem = Str.from_utf8_lossy((parts.last() ?? "").to_utf8().drop_last(4))
		directory = parts.drop_last(1)
		root = if directory.is_empty() {
			"main.roc"
		} else {
			"${Str.join_with(directory, "/")}/main.roc"
		}
		tested = if Path.is_file!(Path.utf8(root))? {
			root_source = Path.read_utf8!(Path.utf8(root))?
			root_source.contains(stem) and
				build_source.contains("\"${root}\"") and
					source.contains("${stem}.plan(") and
						List.any(
							Tidy.indexed_lines(source),
							|line| Tidy.is_expect(line.text),
						)
		} else {
			Bool.False
		}
		Ok({ path, root, tested })
	}

	# Annotated to avoid a compiler hang:
	# https://github.com/roc-lang/roc/issues/11621
	# Remove this workaround once the Roc pin includes the fix.
	planners! : List(Path), Str => Try(List(Planner), _)
	planners! = |paths, build_source|
		match paths {
			[] => Ok([])
			[path, .. as rest] => {
				source = Path.read_utf8!(path)?
				current = if Tidy.is_planner(source) {
					relative = Tidy.relative_path(Path.display(path))
					[Tidy.planner_tested!(relative, source, build_source)?]
				} else {
					[]
				}
				remaining = Tidy.planners!(rest, build_source)?
				Ok(current.concat(remaining))
			}
		}

	# An empty planner set fails too, so renaming `plan` cannot go vacuous.
	implementation_diagnostics! = |paths| {
		build_source = Path.read_utf8!(Path.utf8("build.zig"))?
		found = Tidy.planners!(paths, build_source)?
		if found.is_empty() {
			Ok([
				Tidy.Diagnostic.{
					kind: MissingImplementationTest("plan : Ir, Request"),
					line: 1,
					path: "no backend planner found",
				},
			])
		} else {
			Ok(
				found.keep_if(|planner| !planner.tested).map(
					|planner|
						Tidy.Diagnostic.{
							kind: MissingImplementationTest(planner.root),
							line: 1,
							path: planner.path,
						},
				),
			)
		}
	}

	check_paths! = |paths|
		match paths {
			[] => Ok([])
			[path, .. as rest] => {
				display_path = Tidy.relative_path(Path.display(path))
				source = Path.read_utf8!(path)?
				diagnostics = Tidy.check_file(source).map(
					|violation|
						Tidy.Diagnostic.{
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
					MissingExpectComment | MissingModuleComment => Bool.True
					_ => Bool.False
				},
		)
		long_lines = diagnostics.keep_if(
			|diagnostic|
				match diagnostic.kind {
					LineTooLong(_) => Bool.True
					_ => Bool.False
				},
		)
		static_joins = diagnostics.keep_if(
			|diagnostic|
				match diagnostic.kind {
					StaticLiteralJoin => Bool.True
					_ => Bool.False
				},
		)
		numeric_byte_comparisons = diagnostics.keep_if(
			|diagnostic|
				match diagnostic.kind {
					NumericAsciiByteComparison => Bool.True
					_ => Bool.False
				},
		)
		missing_tests = diagnostics.keep_if(
			|diagnostic|
				match diagnostic.kind {
					MissingImplementationTest(_) => Bool.True
					_ => Bool.False
				},
		)

		if !missing_comments.is_empty() {
			header = "Missing module or expect comments (${
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
					_ => 0
				}
				Stderr.line!(
					"  ${diagnostic.path}:${line} (${U64.to_str(width)} codepoints)",
				)?
			}
		}
		if !static_joins.is_empty() {
			if !missing_comments.is_empty() or !long_lines.is_empty() {
				Stderr.line!("")?
			}
			header = "Direct static literal-list Str.join_with calls (${
				U64.to_str(static_joins.len())
			}):"
			Stderr.line!(Tidy.colorize(Tidy.ansi_red, header))?
			for diagnostic in static_joins {
				line = U64.to_str(diagnostic.line)
				Stderr.line!("  ${diagnostic.path}:${line}")?
			}
		}
		if !numeric_byte_comparisons.is_empty() {
			if
				!missing_comments.is_empty() or
					!long_lines.is_empty() or
						!static_joins.is_empty()
					{
						Stderr.line!("")?
					}
			header = "Numeric ASCII byte comparisons (${
				U64.to_str(numeric_byte_comparisons.len())
			}):"
			Stderr.line!(Tidy.colorize(Tidy.ansi_red, header))?
			for diagnostic in numeric_byte_comparisons {
				line = U64.to_str(diagnostic.line)
				Stderr.line!("  ${diagnostic.path}:${line}")?
			}
		}
		if !missing_tests.is_empty() {
			Stderr.line!("")?
			Stderr.line!(Tidy.colorize(Tidy.ansi_red, "Missing backend planner tests:"))?
			for diagnostic in missing_tests {
				test_path = match diagnostic.kind {
					MissingImplementationTest(path) => path
					_ => ""
				}
				Stderr.line!("  ${diagnostic.path} -> ${test_path}")?
			}
		}
		if !diagnostics.is_empty() {
			Stderr.line!("")?
		}
		Stderr.line!("Checks:")?
		Tidy.print_check!("Module and expect comments", missing_comments.is_empty())?
		Tidy.print_check!("Backend planner tests", missing_tests.is_empty())?
		Tidy.print_check!("80-codepoint line limit", long_lines.is_empty())?
		Tidy.print_check!(
			"No direct static literal-list Str.join_with calls",
			static_joins.is_empty(),
		)?
		Tidy.print_check!(
			"Character literals in ASCII byte comparisons",
			numeric_byte_comparisons.is_empty(),
		)?

		count = diagnostics.len()
		label = if count == 1 "violation" else "violations"
		total = "Total: ${U64.to_str(count)} ${label}"
		color = if diagnostics.is_empty() Tidy.ansi_green else Tidy.ansi_red
		Stderr.line!(Tidy.colorize(color, total))
	}

	run! = |paths| {
		whole_repository = paths.is_empty()
		roc_files = if whole_repository {
			Tidy.discover!(Path.utf8("."))?
		} else {
			paths.map(Path.utf8)
		}
		file_diagnostics = Tidy.check_paths!(roc_files)?
		implementation_diagnostics = if whole_repository {
			Tidy.implementation_diagnostics!(roc_files)?
		} else {
			[]
		}
		diagnostics = file_diagnostics.concat(implementation_diagnostics)
		Tidy.print_report!(diagnostics)?
		if diagnostics.is_empty() {
			Ok({})
		} else {
			Err(Exit(1))
		}
	}
}
