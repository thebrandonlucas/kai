# Represents the body of a config block, and all the parsing
# operations that can be performed on it. For example, a
# block for a StdPlugin Kaifile would be the contents of 
# `shell` e.g.:
#
# ```Kaifile
#  shell {
#   pkgs: ["cowsay", "fortune"]
# }
# ```
#
# We'll use this shell example to explain code below
import Bytes

Body := [].{
	# For now, we only have String or StringList
	# to represent our values.
	# 
	# ex: `["cowsay", ...]` is a StringList.
	ValueShape : [String, StringList]
	# Whether a Field is required or not.
	# In `shell`, `pkgs` is required.
	Presence : [Optional, Required]
	# ex: `pkgs` in `pkgs: ["cowsay", ...]`
	Field := {
		name : Str,
		presence : Presence,
		value : ValueShape,
	}
	# Overall shape of the config Body is a list of fields.
	Shape : [Object(List(Field))]

	Value : [StringValue(Str), StringListValue(List(Str))]
	Entry := { name : Str, value : Value }
	Configuration : [Config(List(Entry))]

	# The various errors our config writer may encode.
	DiagnosticKind : [
		DuplicateField(Str),
		InvalidSyntax(Str),
		InvalidString(Str),
		MissingField(Str),
		UnknownField(Str),
		WrongListItem(Str),
		WrongType(
			{
				expected : ValueShape,
				field : Str,
			},
		),
	]
	# We want to be able to tell the user what they did wrong (kind)
	# and point to the exact location of the error (byte_offset).
	Diagnostic := {
		byte_offset : U64,
		kind : DiagnosticKind,
	}

	# FIX why is this separate from the other error?
	AccessError : [
		MissingField(Str),
		WrongType(
			{
				expected : ValueShape,
				field : Str,
			},
		),
	]

	# Declare which fields the Body has.
	object : List(Field) -> Shape
	object = |fields| Object(fields)

	# Mark a field as required
	#
	# ex: Body.required("pkgs", StringList)
	required : Str, ValueShape -> Field
	required = |name, value| { name, presence: Required, value }

	# Mark a field as optional
	optional : Str, ValueShape -> Field
	optional = |name, value| { name, presence: Optional, value }

	# Some commands in the future may have no Body fields.
	empty : Configuration
	empty = Config([])

	# Take the read-in config.kai string data, validate
	# it against the desired Shape, and read it into Roc values.
	#
	# ex: `pkgs: ["cowsay", ..]` -> validated roc data.
	parse : Shape, Str -> Try(Configuration, Diagnostic)
	parse = |shape, body_text| {
		fields = match shape {
			Object(object_fields) => object_fields
		}
		bytes = body_text.to_utf8()
		parsed = Body.parse_fields(
			bytes,
			Body.skip_trivia(bytes, 0),
			fields,
			[],
		)?
		Body.require_fields(
			fields,
			parsed.entries,
			bytes.len(),
		)?
		Ok(Config(parsed.entries))
	}

	# Parse each `name: value` field until its body ends.
	parse_fields :
		List(U8),
		U64,
		List(Field),
		List(Entry) ->
			Try(
				{ entries : List(Entry), rest : U64 },
				Diagnostic,
			)
	parse_fields = |bytes, index, fields, entries| {
		start = Body.skip_trivia(bytes, index)
		# If body ends after e.g. `pkgs: [..]`, return that entry.
		if start >= bytes.len() {
			Ok({ entries, rest: start })
		} else {
			# else, parse its next field.
			# throwing if given field name unknown.
			name_result = Body.parse_name(bytes, start)?
			name = name_result.name
			field = Body.find_field(fields, name) ? |_| {
				byte_offset: start,
				kind: UnknownField(name),
			}
			# Check for duplicates
			if Body.has_entry(entries, name) {
				Err({
					byte_offset: start,
					kind: DuplicateField(name),
				})
			} else {
				# Check for expected colon syntax. If good, parse value.
				colon_index = Body.skip_trivia(bytes, name_result.rest)
				if Body.byte_at(bytes, colon_index) != Bytes.colon {
					Err({
						byte_offset: colon_index,
						kind: InvalidSyntax("expected ':' after field '${name}'"),
					})
				} else {
					value_start = Body.skip_trivia(bytes, colon_index + 1)
					parsed_value = Body.parse_value(bytes, value_start, field)?
					Body.parse_fields(
						bytes,
						parsed_value.rest,
						fields,
						entries.append({ name, value: parsed_value.value }),
					)
				}
			}
		}
	}

	# Parse a field according to its declared value shape.
	parse_value :
		List(U8),
		U64,
		Field ->
			Try(
				{
					rest : U64,
					value : Value,
				},
				Diagnostic,
			)
	parse_value = |bytes, index, field|
		match field.value {
			String =>
			# Strings must begin with double quotes
				if Body.byte_at(bytes, index) != Bytes.double_quote {
					Err({
						byte_offset: index,
						kind: WrongType({
							expected: String,
							field: field.name,
						}),
					})
				} else {
					parsed = Body.parse_string(bytes, index)?
					Ok({ rest: parsed.rest, value: StringValue(parsed.value) })
				}
			StringList =>
			# String-list values must open with `[`.
				if Body.byte_at(bytes, index) != Bytes.open_square_bracket {
					Err({
						byte_offset: index,
						kind: WrongType({
							expected: StringList,
							field: field.name,
						}),
					})
				} else {
					parsed = Body.parse_string_list(
						bytes,
						index + 1,
						field.name,
						[],
						Bool.True,
					)?
					Ok({
						rest: parsed.rest,
						value: StringListValue(parsed.values),
					})
				}
			}

	# StringList field uses this to parse e.g. `pkgs: ["cowsay", ..]`.
	parse_string_list :
		List(U8),
		U64,
		Str,
		List(Str),
		Bool ->
			Try(
				{ rest : U64, values : List(Str) },
				Diagnostic,
			)
	parse_string_list = |bytes, index, field_name, values, allow_end| {
		start = Body.skip_trivia(bytes, index)
		byte = Body.byte_at(bytes, start)
		# If a list e.g. `pkgs: [` ends before being completed.
		if start >= bytes.len() {
			Err({
				byte_offset: start,
				kind: InvalidSyntax("unterminated list in field '${field_name}'"),
			})
			# `pkgs: []` closes with `]` before any item, which is allowed.
		} else if byte == Bytes.close_square_bracket and allow_end {
			Ok({ rest: start + 1, values })
			# `pkgs: ["cowsay",]` wrongly closes with `]` after a comma.
		} else if byte == Bytes.close_square_bracket {
			Err({
				byte_offset: start,
				kind: InvalidSyntax("expected a string after ',' in field '${field_name}'"),
			})
			# `pkgs: [1]` has an item not opened with `"` as a string.
		} else if byte != Bytes.double_quote {
			Err({ byte_offset: start, kind: WrongListItem(field_name) })
		} else {
			# `pkgs: ["cowsay"..]` parses the current quoted item.
			parsed = Body.parse_string(bytes, start)?
			next = Body.skip_trivia(bytes, parsed.rest)
			next_byte = Body.byte_at(bytes, next)
			# Another package follows the `,` separator.
			if next_byte == Bytes.comma {
				Body.parse_string_list(bytes, next + 1, field_name, values.append(parsed.value), Bool.False)
				# `]` closes the completed `pkgs` list.
			} else if next_byte == Bytes.close_square_bracket {
				Ok({ rest: next + 1, values: values.append(parsed.value) })
			} else {
				# `pkgs: ["cowsay" "fortune"]` has neither `,` nor `]` after an item.
				Err({ byte_offset: next, kind: InvalidSyntax("expected ',' or ']' in field '${field_name}'") })
			}
		}
	}

	# Decode a quoted package name such as `"cowsay"`.
	parse_string : List(U8), U64 -> Try({ rest : U64, value : Str }, Diagnostic)
	parse_string = |bytes, start| {
		end = Body.find_string_end(bytes, start + 1, Bool.False)?
		raw = Str.from_utf8(bytes.sublist({ start, len: end - start + 1 })) ?? ""
		decoded : Try(Str, Json.ParseErr)
		decoded = Json.parse(raw)
		match decoded {
			# `"cowsay"` becomes the Roc string `cowsay`.
			Ok(value) => Ok({ rest: end + 1, value })
			# `pkgs: ["\q"]` has an invalid JSON escape.
			Err(_) => Err({ byte_offset: start, kind: InvalidString("invalid string") })
		}
	}

	# Locate the closing quote of a package name such as `"cowsay"`.
	find_string_end : List(U8), U64, Bool -> Try(U64, Diagnostic)
	find_string_end = |bytes, index, escaped|
	# `pkgs: ["cowsay` reaches the end without a closing quote.
		if index >= bytes.len() {
			Err({ byte_offset: index, kind: InvalidString("unterminated string") })
		} else {
			# `pkgs: ["cowsay"]` still has a byte to inspect.
			byte = Body.byte_at(bytes, index)
			# The byte after an escape in `pkgs: ["cow\"say"]` is string data.
			if escaped {
				Body.find_string_end(bytes, index + 1, Bool.False)
				# `\` escapes the following byte in the package string.
			} else if byte == Bytes.backslash {
				Body.find_string_end(bytes, index + 1, Bool.True)
				# `"` closes the package string.
			} else if byte == Bytes.double_quote {
				Ok(index)
			} else {
				# Ordinary bytes in `cowsay` are skipped while finding the string's end.
				Body.find_string_end(bytes, index + 1, Bool.False)
			}
		}

	# Read the field name `pkgs` before its colon.
	parse_name : List(U8), U64 -> Try({ name : Str, rest : U64 }, Diagnostic)
	parse_name = |bytes, start| {
		first = Body.byte_at(bytes, start)
		# `1pkgs: []` cannot start a field name with a digit.
		if !Body.is_name_start(first) {
			Err({ byte_offset: start, kind: InvalidSyntax("expected a field name") })
		} else {
			# `pkgs: ["cowsay"]` collects `pkgs` and stops before `:`.
			end = Body.find_name_end(bytes, start + 1)
			name = Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""
			Ok({ name, rest: end })
		}
	}

	# Find where a field name such as `pkgs` ends.
	find_name_end : List(U8), U64 -> U64
	find_name_end = |bytes, index|
	# Each remaining letter in `pkgs` advances the end.
		if index < bytes.len() and Body.is_name_continue(Body.byte_at(bytes, index)) {
			Body.find_name_end(bytes, index + 1)
		} else {
			# The `:` after `pkgs` marks the name's end.
			index
		}

	# Ignore spaces, newlines, and `#` comments around shell fields.
	skip_trivia : List(U8), U64 -> U64
	skip_trivia = |bytes, index|
	# Trivia after the `pkgs` field may run to the end of the body.
		if index >= bytes.len() {
			index
		} else {
			# Otherwise inspect the next byte before or after `pkgs`.
			byte = Body.byte_at(bytes, index)
			# Spaces before `pkgs` are ignored.
			if Body.is_whitespace(byte) {
				Body.skip_trivia(bytes, index + 1)
				# `# package note` starts a comment.
			} else if byte == Bytes.hash {
				Body.skip_trivia(bytes, Body.skip_comment(bytes, index + 1))
			} else {
				# The `p` in `pkgs` is significant, so parsing resumes here.
				index
			}
		}

	# Skip from `# package note` to its line ending.
	skip_comment : List(U8), U64 -> U64
	skip_comment = |bytes, index|
	# A line feed or end-of-body terminates the shell comment.
		if index >= bytes.len() or Body.byte_at(bytes, index) == Bytes.line_feed {
			index
		} else {
			# Bytes inside the shell comment are skipped until LF or end-of-body.
			Body.skip_comment(bytes, index + 1)
		}

	# Recognize formatting around `pkgs: ["cowsay", "fortune"]`.
	is_whitespace : U8 -> Bool
	is_whitespace = |byte|
		byte == Bytes.space or
			byte == Bytes.horizontal_tab or
				byte == Bytes.line_feed or
					byte == Bytes.carriage_return

	# Accept the first `p` in the `pkgs` field name.
	is_name_start : U8 -> Bool
	is_name_start = |byte|
		(byte >= Bytes.uppercase_a and byte <= Bytes.uppercase_z) or
			(byte >= Bytes.lowercase_a and byte <= Bytes.lowercase_z) or
				byte == Bytes.underscore

	# Accept the remaining letters in `pkgs` or digits in another valid field name.
	is_name_continue : U8 -> Bool
	is_name_continue = |byte|
		Body.is_name_start(byte) or
			(byte >= Bytes.digit_zero and byte <= Bytes.digit_nine)

	# Safely inspect the shell body even at its end.
	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index| bytes.get(index) ?? Bytes.nul

	# Match parsed `pkgs` against the shell body's declared field.
	find_field : List(Field), Str -> Try(Field, [NotFound])
	find_field = |fields, name|
		match fields {
			# `extra` reaches the end because the shell body only declares `pkgs`.
			[] => Err(NotFound)
			# A nonempty shell schema compares its next declaration with the name.
			[first, .. as rest] =>
			# The parsed name `pkgs` matches the shell's required field.
				if first.name == name {
					Ok(first)
				} else {
					# An unknown name continues past `pkgs` and eventually returns NotFound.
					Body.find_field(rest, name)
				}
			}

	# Detect whether `pkgs` was already parsed.
	has_entry : List(Entry), Str -> Bool
	has_entry = |entries, name|
		match entries {
			# Before parsing the shell's first field, no `pkgs` entry exists.
			[] => Bool.False
			# After parsing, compare `pkgs` or search any later entries.
			[first, .. as rest] => first.name == name or Body.has_entry(rest, name)
		}

	# Ensure the shell's required `pkgs` entry was provided.
	require_fields : List(Field), List(Entry), U64 -> Try({}, Diagnostic)
	require_fields = |fields, entries, end|
		match fields {
			# Once every shell field was checked, validation succeeds.
			[] => Ok({})
			# A remaining shell field is checked for required presence.
			[first, .. as rest] =>
			# An empty shell body is missing required `pkgs`.
				if first.presence == Required and !Body.has_entry(entries, first.name) {
					Err({ byte_offset: end, kind: MissingField(first.name) })
				} else {
					# A present `pkgs`, or an omitted optional field, allows checking the rest.
					Body.require_fields(rest, entries, end)
				}
			}

	# Locate `pkgs` in the shell's validated entries.
	find_entry : List(Entry), Str -> Try(Value, AccessError)
	find_entry = |entries, name|
		match entries {
			# A malformed shell configuration with no `pkgs` reports it missing.
			[] => Err(MissingField(name))
			# A nonempty shell configuration compares the next entry.
			[first, .. as rest] =>
			# The `pkgs` entry returns its validated value.
				if first.name == name {
					Ok(first.value)
				} else {
					# A lookup for another shell field continues through the entries.
					Body.find_entry(rest, name)
				}
			}

	# Read a validated String field, such as an optional shell `description`.
	get_string : Configuration, Str -> Try(Str, AccessError)
	get_string = |Config(entries), name|
		match Body.find_entry(entries, name)? {
			# `description: "development shell"` returns its text.
			StringValue(value) => Ok(value)
			# Asking for the shell's `pkgs` list as a string is an error.
			StringListValue(_) => Err(WrongType({ expected: String, field: name }))
		}

	# Read the shell's validated `pkgs` StringList.
	get_strings : Configuration, Str -> Try(List(Str), AccessError)
	get_strings = |Config(entries), name|
		match Body.find_entry(entries, name)? {
			# `pkgs: ["cowsay"]` returns its list.
			StringListValue(values) => Ok(values)
			# Asking for a shell `description` string as a list is an error.
			StringValue(_) => Err(WrongType({ expected: StringList, field: name }))
		}

	# An optional shell String field such as `description` could use this.
	maybe_string : Configuration, Str -> Try([None, Some(Str)], AccessError)
	maybe_string = |Config(entries), name|
		match Body.find_entry(entries, name) {
			# An omitted optional shell `description` returns None.
			Err(MissingField(_)) => Ok(None)
			# Any lookup type error for `description` is preserved.
			Err(WrongType(problem)) => Err(WrongType(problem))
			# `description: "development shell"` returns Some("development shell").
			Ok(StringValue(value)) => Ok(Some(value))
			# A list stored under `description` cannot be read as an optional string.
			Ok(StringListValue(_)) => Err(WrongType({ expected: String, field: name }))
		}

	# The shell's `pkgs` StringList can be read through an optional accessor.
	maybe_strings : Configuration, Str -> Try([None, Some(List(Str))], AccessError)
	maybe_strings = |Config(entries), name|
		match Body.find_entry(entries, name) {
			# No `pkgs` entry returns None; required-field validation normally prevents this.
			Err(MissingField(_)) => Ok(None)
			# Any lookup type error for `pkgs` is preserved.
			Err(WrongType(problem)) => Err(WrongType(problem))
			# `pkgs: ["cowsay"]` returns Some(["cowsay"]).
			Ok(StringListValue(values)) => Ok(Some(values))
			# A string stored under `pkgs` cannot be read as an optional list.
			Ok(StringValue(_)) => Err(WrongType({ expected: StringList, field: name }))
		}

	# Turn a shell body diagnostic into user-facing text.
	describe : Diagnostic -> Str
	describe = |diagnostic|
		match diagnostic.kind {
			# Two `pkgs` fields become `duplicate field 'pkgs'`.
			DuplicateField(name) => "duplicate field '${name}'"
			# A missing colon after `pkgs` keeps its specific syntax message.
			InvalidSyntax(message) => message
			# An invalid escape in a package name keeps its string error message.
			InvalidString(message) => message
			# An empty shell body reports `missing required field 'pkgs'`.
			MissingField(name) => "missing required field '${name}'"
			# The shell's undeclared `extra` field reports `unknown field 'extra'`.
			UnknownField(name) => "unknown field '${name}'"
			# `pkgs: [1]` reports that package items must be strings.
			WrongListItem(field) => "items in field '${field}' must be strings"
			# `pkgs: "cowsay"` reports that `pkgs` must be a list of strings.
			WrongType({ expected, field }) => "field '${field}' must be ${Body.shape_name(expected)}"
		}

	# Shell diagnostics use this to name an expected value shape.
	shape_name : ValueShape -> Str
	shape_name = |shape|
		match shape {
			# An optional shell `description` expectation is described as `a string`.
			String => "a string"
			# The shell's `pkgs` expectation is described as `a list of strings`.
			StringList => "a list of strings"
		}
}
