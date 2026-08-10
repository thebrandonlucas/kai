# Parse and validate the generic fields inside a config block against a shape
# declared by its plugin. Comments use the StdPlugin `shell` body as a running
# example:
#
# ```kai
# shell {
#     pkgs: ["cowsay", "fortune"]
# }
# ```
import Bytes

Body := [].{
	# -- Public configuration model -----------------------------------------

	# Fields currently support string or string-list values. For example,
	# `["cowsay", ...]` in the StdPlugin `pkgs` field is a StringList.
	ValueShape : [String, StringList]
	# Whether a declared field must be present. For example, StdPlugin requires
	# `pkgs` in its `shell` body.
	Presence : [Optional, Required]
	# A field declaration. For example, `pkgs` names the field in
	# `pkgs: ["cowsay", ...]`.
	Field := {
		name : Str,
		presence : Presence,
		value : ValueShape,
	}
	# The declared shape of a body, currently an object containing fields.
	Shape : [Object(List(Field))]

	# Values and entries produced after parsing and validation.
	Value : [StringValue(Str), StringListValue(List(Str))]
	Entry := { name : Str, value : Value }
	Configuration : [Config(List(Entry))]

	# -- Parse diagnostics ---------------------------------------------------

	# Failures found while parsing or validating source text.
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

	# Access errors are separate from parse diagnostics because access happens
	# after validation, against Roc values with no source position. Parse
	# diagnostics retain the source byte offset needed to point at invalid text.
	AccessError : [
		MissingField(Str),
		WrongType(
			{
				expected : ValueShape,
				field : Str,
			},
		),
	]

	# -- Shape construction --------------------------------------------------

	# Declare which fields a body has.
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

	# Represent a validated body with no entries. For example, a plugin command
	# whose body declares no fields can use this value.
	empty : Configuration
	empty = Config([])

	# -- Field parsing and validation ---------------------------------------

	# Parse body text into Roc values and validate it against the declared
	# Shape. For example, `pkgs: ["cowsay", ..]` becomes validated entries.
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

	# Parse each generic `name: value` field until the body ends.
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
		# If the body ends after a field, return all entries parsed so far. For
		# example, this happens after StdPlugin's `pkgs: [..]`.
		if start >= bytes.len() {
			Ok({ entries, rest: start })
		} else {
			# Otherwise parse the next field, failing if its name was not declared.
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

	# Parse a generic StringList field. StdPlugin uses this for
	# `pkgs: ["cowsay", ..]`.
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
		# A list that reaches the body end before `]` is unterminated. For
		# example, `pkgs: [` fails here.
		if start >= bytes.len() {
			Err({
				byte_offset: start,
				kind: InvalidSyntax("unterminated list in field '${field_name}'"),
			})
			# An empty list may close before any item; for example, `pkgs: []`.
		} else if byte == Bytes.close_square_bracket and allow_end {
			Ok({ rest: start + 1, values })
			# A list cannot close directly after a comma; for example,
			# `pkgs: ["cowsay",]`.
		} else if byte == Bytes.close_square_bracket {
			Err({
				byte_offset: start,
				kind: InvalidSyntax("expected a string after ',' in field '${field_name}'"),
			})
			# Every item must open with `"`; for example, `pkgs: [1]` fails.
		} else if byte != Bytes.double_quote {
			Err({ byte_offset: start, kind: WrongListItem(field_name) })
		} else {
			# Parse the current quoted item; in `pkgs: ["cowsay"..]`, this is
			# `"cowsay"`.
			parsed = Body.parse_string(bytes, start)?
			next = Body.skip_trivia(bytes, parsed.rest)
			next_byte = Body.byte_at(bytes, next)
			# A comma introduces another string item; in `pkgs`, another package.
			if next_byte == Bytes.comma {
				Body.parse_string_list(bytes, next + 1, field_name, values.append(parsed.value), Bool.False)
				# `]` closes the completed list, such as StdPlugin's `pkgs` list.
			} else if next_byte == Bytes.close_square_bracket {
				Ok({ rest: next + 1, values: values.append(parsed.value) })
			} else {
				# An item must be followed by `,` or `]`; for example,
				# `pkgs: ["cowsay" "fortune"]` fails.
				Err({ byte_offset: next, kind: InvalidSyntax("expected ',' or ']' in field '${field_name}'") })
			}
		}
	}

	# Decode any quoted string value. For example, a `pkgs` item `"cowsay"`
	# becomes the Roc string `cowsay`.
	parse_string : List(U8), U64 -> Try({ rest : U64, value : Str }, Diagnostic)
	parse_string = |bytes, start| {
		end = Body.find_string_end(bytes, start + 1, Bool.False)?
		raw = Str.from_utf8(bytes.sublist({ start, len: end - start + 1 })) ?? ""
		decoded : Try(Str, Json.ParseErr)
		decoded = Json.parse(raw)
		match decoded {
			# A valid JSON string is returned decoded; for example, `"cowsay"`
			# becomes `cowsay`.
			Ok(value) => Ok({ rest: end + 1, value })
			# Invalid JSON escapes fail; for example, `pkgs: ["\q"]`.
			Err(_) => Err({ byte_offset: start, kind: InvalidString("invalid string") })
		}
	}

	# -- Lexical helpers -----------------------------------------------------

	# Locate a string's closing quote. For example, find the end of the
	# `"cowsay"` item in StdPlugin's `pkgs` list.
	find_string_end : List(U8), U64, Bool -> Try(U64, Diagnostic)
	find_string_end = |bytes, index, escaped|
	# Reaching the body end without a closing quote is invalid; for example,
	# `pkgs: ["cowsay`.
		if index >= bytes.len() {
			Err({ byte_offset: index, kind: InvalidString("unterminated string") })
		} else {
			# Otherwise inspect the next string byte, such as a byte in `"cowsay"`.
			byte = Body.byte_at(bytes, index)
			# The byte after an escape is string data; for example, the quote in
			# `pkgs: ["cow\"say"]` does not end the string.
			if escaped {
				Body.find_string_end(bytes, index + 1, Bool.False)
				# `\` escapes the following string byte, including in a package name.
			} else if byte == Bytes.backslash {
				Body.find_string_end(bytes, index + 1, Bool.True)
				# An unescaped `"` closes the string, such as a package string.
			} else if byte == Bytes.double_quote {
				Ok(index)
			} else {
				# Ordinary string bytes are skipped; for example, each byte in `cowsay`.
				Body.find_string_end(bytes, index + 1, Bool.False)
			}
		}

	# Read a field name before its colon. For example, read `pkgs`.
	parse_name : List(U8), U64 -> Try({ name : Str, rest : U64 }, Diagnostic)
	parse_name = |bytes, start| {
		first = Body.byte_at(bytes, start)
		# A field name cannot start with a digit; for example, `1pkgs: []`.
		if !Body.is_name_start(first) {
			Err({ byte_offset: start, kind: InvalidSyntax("expected a field name") })
		} else {
			# Collect through the name and stop before `:`; for example, at the end
			# of `pkgs` in `pkgs: ["cowsay"]`.
			end = Body.find_name_end(bytes, start + 1)
			name = Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""
			Ok({ name, rest: end })
		}
	}

	# Find the end of any field name, such as `pkgs`.
	find_name_end : List(U8), U64 -> U64
	find_name_end = |bytes, index|
	# Each valid continuation byte advances the end; letters advance through
	# the example name `pkgs`.
		if index < bytes.len() and Body.is_name_continue(Body.byte_at(bytes, index)) {
			Body.find_name_end(bytes, index + 1)
		} else {
			# A non-name byte marks the end; for example, the `:` after `pkgs`.
			index
		}

	# Ignore spaces, newlines, and `#` comments around any body field. The
	# StdPlugin example permits this trivia around `pkgs`.
	skip_trivia : List(U8), U64 -> U64
	skip_trivia = |bytes, index|
	# Trailing trivia may run to the body end, including after `pkgs`.
		if index >= bytes.len() {
			index
		} else {
			# Otherwise inspect the next byte around the current field.
			byte = Body.byte_at(bytes, index)
			# Whitespace is ignored; for example, spaces before `pkgs`.
			if Body.is_whitespace(byte) {
				Body.skip_trivia(bytes, index + 1)
				# `#` starts a body comment; for example, `# package note`.
			} else if byte == Bytes.hash {
				Body.skip_trivia(bytes, Body.skip_comment(bytes, index + 1))
			} else {
				# A nontrivia byte resumes parsing; for example, the `p` in `pkgs`.
				index
			}
		}

	# Skip any body comment to its line ending, such as `# package note`.
	skip_comment : List(U8), U64 -> U64
	skip_comment = |bytes, index|
	# A line feed or end-of-body terminates the comment.
		if index >= bytes.len() or Body.byte_at(bytes, index) == Bytes.line_feed {
			index
		} else {
			# Comment bytes are skipped until LF or end-of-body.
			Body.skip_comment(bytes, index + 1)
		}

	# Recognize body formatting whitespace, such as the spacing around
	# `pkgs: ["cowsay", "fortune"]`.
	is_whitespace : U8 -> Bool
	is_whitespace = |byte|
		byte == Bytes.space or
			byte == Bytes.horizontal_tab or
				byte == Bytes.line_feed or
					byte == Bytes.carriage_return

	# Accept a valid first field-name byte, such as the `p` in `pkgs`.
	is_name_start : U8 -> Bool
	is_name_start = |byte|
		(byte >= Bytes.uppercase_a and byte <= Bytes.uppercase_z) or
			(byte >= Bytes.lowercase_a and byte <= Bytes.lowercase_z) or
				byte == Bytes.underscore

	# Accept valid continuation bytes, such as the remaining letters in `pkgs`
	# or digits in another field name.
	is_name_continue : U8 -> Bool
	is_name_continue = |byte|
		Body.is_name_start(byte) or
			(byte >= Bytes.digit_zero and byte <= Bytes.digit_nine)

	# Safely inspect any body even at its end.
	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index| bytes.get(index) ?? Bytes.nul

	# -- Schema and entry lookup --------------------------------------------

	# Match a parsed name against the body's declarations. For example, match
	# `pkgs` against StdPlugin's shell shape.
	find_field : List(Field), Str -> Try(Field, [NotFound])
	find_field = |fields, name|
		match fields {
			# An undeclared name reaches the end. For example, `extra` is absent
			# when the shell body declares only `pkgs`.
			[] => Err(NotFound)
			# A nonempty schema compares its next declaration with the parsed name.
			[first, .. as rest] =>
			# A matching declaration is returned; for example, shell's `pkgs` field.
				if first.name == name {
					Ok(first)
				} else {
					# An unknown name continues through declarations and returns NotFound.
					Body.find_field(rest, name)
				}
			}

	# Detect whether any field was already parsed, such as `pkgs`.
	has_entry : List(Entry), Str -> Bool
	has_entry = |entries, name|
		match entries {
			# Before parsing the first field, no entry exists, including `pkgs`.
			[] => Bool.False
			# Compare the requested name or search later entries.
			[first, .. as rest] => first.name == name or Body.has_entry(rest, name)
		}

	# Ensure every required declaration has an entry. For example, StdPlugin's
	# shell body must provide `pkgs`.
	require_fields : List(Field), List(Entry), U64 -> Try({}, Diagnostic)
	require_fields = |fields, entries, end|
		match fields {
			# Once every declared field was checked, validation succeeds.
			[] => Ok({})
			# Check each remaining declaration for required presence.
			[first, .. as rest] =>
			# A missing required field fails; for example, an empty shell body lacks
			# required `pkgs`.
				if first.presence == Required and !Body.has_entry(entries, first.name) {
					Err({ byte_offset: end, kind: MissingField(first.name) })
				} else {
					# A present required field, or any omitted optional field, allows the
					# remaining declarations to be checked.
					Body.require_fields(rest, entries, end)
				}
			}

	# -- Validated value access ---------------------------------------------

	# Locate a named value in validated entries. For example, locate `pkgs` in
	# the StdPlugin shell configuration.
	find_entry : List(Entry), Str -> Try(Value, AccessError)
	find_entry = |entries, name|
		match entries {
			# Exhausting the entries reports the requested field missing.
			[] => Err(MissingField(name))
			# A nonempty configuration compares the next entry.
			[first, .. as rest] =>
			# A matching entry returns its value; for example, the `pkgs` list.
				if first.name == name {
					Ok(first.value)
				} else {
					# A nonmatching lookup continues through the remaining entries.
					Body.find_entry(rest, name)
				}
			}

	# Read any validated String field. For example, a shell shape could declare
	# an optional `description`.
	get_string : Configuration, Str -> Try(Str, AccessError)
	get_string = |Config(entries), name|
		match Body.find_entry(entries, name)? {
			# A StringValue returns its text; for example, `description`.
			StringValue(value) => Ok(value)
			# A StringListValue has the wrong type; for example, shell's `pkgs`.
			StringListValue(_) => Err(WrongType({ expected: String, field: name }))
		}

	# Read any validated StringList field. For example, StdPlugin reads the
	# shell's `pkgs` list this way.
	get_strings : Configuration, Str -> Try(List(Str), AccessError)
	get_strings = |Config(entries), name|
		match Body.find_entry(entries, name)? {
			# A StringListValue returns its list; for example, `pkgs: ["cowsay"]`.
			StringListValue(values) => Ok(values)
			# A StringValue has the wrong type; for example, shell `description`.
			StringValue(_) => Err(WrongType({ expected: StringList, field: name }))
		}

	# Read any optional String field. For example, a shell `description` could
	# use this accessor.
	maybe_string : Configuration, Str -> Try([None, Some(Str)], AccessError)
	maybe_string = |Config(entries), name|
		match Body.find_entry(entries, name) {
			# An omitted optional field returns None; for example, `description`.
			Err(MissingField(_)) => Ok(None)
			# Any lookup type error is preserved.
			Err(WrongType(problem)) => Err(WrongType(problem))
			# A string returns Some; for example, `description: "development shell"`.
			Ok(StringValue(value)) => Ok(Some(value))
			# A stored list cannot be read as a string; for example, under
			# `description`.
			Ok(StringListValue(_)) => Err(WrongType({ expected: String, field: name }))
		}

	# Read any optional StringList field. For example, a shape with optional
	# `pkgs` could use this accessor.
	maybe_strings : Configuration, Str -> Try([None, Some(List(Str))], AccessError)
	maybe_strings = |Config(entries), name|
		match Body.find_entry(entries, name) {
			# An omitted optional field returns None. Required-field validation
			# normally prevents this for StdPlugin's `pkgs`.
			Err(MissingField(_)) => Ok(None)
			# Any lookup type error is preserved.
			Err(WrongType(problem)) => Err(WrongType(problem))
			# A list returns Some; for example, `pkgs: ["cowsay"]`.
			Ok(StringListValue(values)) => Ok(Some(values))
			# A stored string cannot be read as a list; for example, under `pkgs`.
			Ok(StringValue(_)) => Err(WrongType({ expected: StringList, field: name }))
		}

	# -- Diagnostic formatting ---------------------------------------------

	# Turn any body diagnostic into user-facing text. Examples below use the
	# StdPlugin shell body.
	describe : Diagnostic -> Str
	describe = |diagnostic|
		match diagnostic.kind {
			# Name a duplicated field; two `pkgs` fields produce this message.
			DuplicateField(name) => "duplicate field '${name}'"
			# Preserve specific syntax text, such as a missing colon after `pkgs`.
			InvalidSyntax(message) => message
			# Preserve string error text, such as an invalid package-name escape.
			InvalidString(message) => message
			# Name a missing required field; an empty shell body reports `pkgs`.
			MissingField(name) => "missing required field '${name}'"
			# Name an undeclared field; shell's `extra` reports this message.
			UnknownField(name) => "unknown field '${name}'"
			# Require string list items; for example, `pkgs: [1]` fails.
			WrongListItem(field) => "items in field '${field}' must be strings"
			# Name the expected shape; `pkgs: "cowsay"` expects a string list.
			WrongType({ expected, field }) => "field '${field}' must be ${Body.shape_name(expected)}"
		}

	# Name an expected value shape in any diagnostic, including shell errors.
	shape_name : ValueShape -> Str
	shape_name = |shape|
		match shape {
			# A String expectation is `a string`; for example, shell `description`.
			String => "a string"
			# A StringList expectation is `a list of strings`; for example, `pkgs`.
			StringList => "a list of strings"
		}
}
