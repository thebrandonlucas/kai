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
			# Another CustomPlugin tag follows the `,` separator.
			if next_byte == Bytes.comma {
				Body.parse_string_list(bytes, next + 1, field_name, values.append(parsed.value), Bool.False)
				# `]` closes CustomPlugin's completed tag list.
			} else if next_byte == Bytes.close_square_bracket {
				Ok({ rest: next + 1, values: values.append(parsed.value) })
			} else {
				# `tags: ["demo" "local"]` has neither `,` nor `]` after an item.
				Err({ byte_offset: next, kind: InvalidSyntax("expected ',' or ']' in field '${field_name}'") })
			}
		}
	}

	# CustomPlugin uses this to JSON-decode the quoted text in `message: "Hello"`.
	parse_string : List(U8), U64 -> Try({ rest : U64, value : Str }, Diagnostic)
	parse_string = |bytes, start| {
		end = Body.find_string_end(bytes, start + 1, Bool.False)?
		raw = Str.from_utf8(bytes.sublist({ start, len: end - start + 1 })) ?? ""
		decoded : Try(Str, Json.ParseErr)
		decoded = Json.parse(raw)
		match decoded {
			# CustomPlugin's `message: "Hello"` becomes the Roc string `Hello`.
			Ok(value) => Ok({ rest: end + 1, value })
			# CustomPlugin's `message: "\q"` has an invalid JSON escape.
			Err(_) => Err({ byte_offset: start, kind: InvalidString("invalid string") })
		}
	}

	# CustomPlugin uses this to locate the closing quote of its `message` string.
	find_string_end : List(U8), U64, Bool -> Try(U64, Diagnostic)
	find_string_end = |bytes, index, escaped|
	# `message: "Hello` reaches the end without a closing quote.
		if index >= bytes.len() {
			Err({ byte_offset: index, kind: InvalidString("unterminated string") })
		} else {
			# `message: "Hello"` still has a byte to inspect.
			byte = Body.byte_at(bytes, index)
			# The byte after an escape in `message: "line\nnext"` is string data.
			if escaped {
				Body.find_string_end(bytes, index + 1, Bool.False)
				# `\` escapes the following byte in CustomPlugin's string.
			} else if byte == Bytes.backslash {
				Body.find_string_end(bytes, index + 1, Bool.True)
				# `"` closes CustomPlugin's string.
			} else if byte == Bytes.double_quote {
				Ok(index)
			} else {
				# Ordinary bytes in CustomPlugin's message are skipped while finding its end.
				Body.find_string_end(bytes, index + 1, Bool.False)
			}
		}

	# CustomPlugin uses this to read the field name `message` before its colon.
	parse_name : List(U8), U64 -> Try({ name : Str, rest : U64 }, Diagnostic)
	parse_name = |bytes, start| {
		first = Body.byte_at(bytes, start)
		# `1message: "Hello"` cannot start a CustomPlugin field name with a digit.
		if !Body.is_name_start(first) {
			Err({ byte_offset: start, kind: InvalidSyntax("expected a field name") })
		} else {
			# `message: "Hello"` collects `message` and stops before `:`.
			end = Body.find_name_end(bytes, start + 1)
			name = Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""
			Ok({ name, rest: end })
		}
	}

	# CustomPlugin uses this to find where a field name such as `message` ends.
	find_name_end : List(U8), U64 -> U64
	find_name_end = |bytes, index|
	# Each remaining letter in CustomPlugin's `message` advances the end.
		if index < bytes.len() and Body.is_name_continue(Body.byte_at(bytes, index)) {
			Body.find_name_end(bytes, index + 1)
		} else {
			# The `:` after CustomPlugin's `message` marks the name's end.
			index
		}

	# CustomPlugin uses this to ignore spaces, newlines, and `#` comments around fields.
	skip_trivia : List(U8), U64 -> U64
	skip_trivia = |bytes, index|
	# Trivia after CustomPlugin's last field may run to the end of the body.
		if index >= bytes.len() {
			index
		} else {
			# Otherwise inspect the next byte after or between CustomPlugin fields.
			byte = Body.byte_at(bytes, index)
			# Spaces before `message` are ignored.
			if Body.is_whitespace(byte) {
				Body.skip_trivia(bytes, index + 1)
				# `# custom note` starts a comment.
			} else if byte == Bytes.hash {
				Body.skip_trivia(bytes, Body.skip_comment(bytes, index + 1))
			} else {
				# The `m` in CustomPlugin's `message` is significant, so parsing resumes here.
				index
			}
		}

	# CustomPlugin uses this to skip from `# custom note` to its line ending.
	skip_comment : List(U8), U64 -> U64
	skip_comment = |bytes, index|
	# A line feed or end-of-body terminates the CustomPlugin comment.
		if index >= bytes.len() or Body.byte_at(bytes, index) == Bytes.line_feed {
			index
		} else {
			# Bytes inside CustomPlugin's comment are skipped until LF or end-of-body.
			Body.skip_comment(bytes, index + 1)
		}

	# CustomPlugin uses this to recognize formatting around `message: "Hello"`.
	is_whitespace : U8 -> Bool
	is_whitespace = |byte|
		byte == Bytes.space or
			byte == Bytes.horizontal_tab or
				byte == Bytes.line_feed or
					byte == Bytes.carriage_return

	# CustomPlugin uses this to accept the first `m` in its `message` field name.
	is_name_start : U8 -> Bool
	is_name_start = |byte|
		(byte >= Bytes.uppercase_a and byte <= Bytes.uppercase_z) or
			(byte >= Bytes.lowercase_a and byte <= Bytes.lowercase_z) or
				byte == Bytes.underscore

	# CustomPlugin uses this to accept later letters or digits in a field name.
	is_name_continue : U8 -> Bool
	is_name_continue = |byte|
		Body.is_name_start(byte) or
			(byte >= Bytes.digit_zero and byte <= Bytes.digit_nine)

	# CustomPlugin's parser uses this for safe lookups even at the end of its body.
	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index| bytes.get(index) ?? Bytes.nul

	# CustomPlugin uses this to match parsed `message` against its declared field.
	find_field : List(Field), Str -> Try(Field, [NotFound])
	find_field = |fields, name|
		match fields {
			# `extra` reaches the end because CustomPlugin only declares `message`.
			[] => Err(NotFound)
			# A nonempty CustomPlugin schema compares its next declaration with the name.
			[first, .. as rest] =>
			# The parsed name `message` matches CustomPlugin's required field.
				if first.name == name {
					Ok(first)
				} else {
					# A later hypothetical CustomPlugin field may match after `message` does not.
					Body.find_field(rest, name)
				}
			}

	# CustomPlugin uses this to detect whether `message` was already parsed.
	has_entry : List(Entry), Str -> Bool
	has_entry = |entries, name|
		match entries {
			# Before parsing CustomPlugin's first field, no `message` entry exists.
			[] => Bool.False
			# After parsing, compare `message` or search any later entries.
			[first, .. as rest] => first.name == name or Body.has_entry(rest, name)
		}

	# CustomPlugin uses this to ensure its required `message` entry was provided.
	require_fields : List(Field), List(Entry), U64 -> Try({}, Diagnostic)
	require_fields = |fields, entries, end|
		match fields {
			# Once every CustomPlugin field was checked, validation succeeds.
			[] => Ok({})
			# A remaining CustomPlugin field is checked for required presence.
			[first, .. as rest] =>
			# An empty CustomPlugin body is missing required `message`.
				if first.presence == Required and !Body.has_entry(entries, first.name) {
					Err({ byte_offset: end, kind: MissingField(first.name) })
				} else {
					# A present `message`, or an omitted optional field, allows checking the rest.
					Body.require_fields(rest, entries, end)
				}
			}

	# CustomPlugin's renderer uses this to locate `message` in validated entries.
	find_entry : List(Entry), Str -> Try(Value, AccessError)
	find_entry = |entries, name|
		match entries {
			# A malformed renderer context with no `message` reports it missing.
			[] => Err(MissingField(name))
			# A nonempty CustomPlugin configuration compares the next entry.
			[first, .. as rest] =>
			# The `message` entry returns its validated value.
				if first.name == name {
					Ok(first.value)
				} else {
					# A renderer searching for a later CustomPlugin field continues through entries.
					Body.find_entry(rest, name)
				}
			}

	# CustomPlugin's renderer uses this to read its validated `message` string.
	get_string : Configuration, Str -> Try(Str, AccessError)
	get_string = |Config(entries), name|
		match Body.find_entry(entries, name)? {
			# CustomPlugin's declared `message` returns its string text.
			StringValue(value) => Ok(value)
			# Asking for a hypothetical CustomPlugin `tags` list as a string is an error.
			StringListValue(_) => Err(WrongType({ expected: String, field: name }))
		}

	# A CustomPlugin StringList field such as `tags` could use this accessor.
	get_strings : Configuration, Str -> Try(List(Str), AccessError)
	get_strings = |Config(entries), name|
		match Body.find_entry(entries, name)? {
			# A validated `tags: ["demo"]` returns its list.
			StringListValue(values) => Ok(values)
			# Asking for CustomPlugin's `message` as a list is an error.
			StringValue(_) => Err(WrongType({ expected: StringList, field: name }))
		}

	# An optional CustomPlugin string field such as `description` could use this.
	maybe_string : Configuration, Str -> Try([None, Some(Str)], AccessError)
	maybe_string = |Config(entries), name|
		match Body.find_entry(entries, name) {
			# An omitted optional CustomPlugin `description` returns None.
			Err(MissingField(_)) => Ok(None)
			# Any lookup type error for `description` is preserved.
			Err(WrongType(problem)) => Err(WrongType(problem))
			# `description: "demo"` returns Some("demo").
			Ok(StringValue(value)) => Ok(Some(value))
			# A list stored under `description` cannot be read as an optional string.
			Ok(StringListValue(_)) => Err(WrongType({ expected: String, field: name }))
		}

	# An optional CustomPlugin StringList field such as `tags` could use this.
	maybe_strings : Configuration, Str -> Try([None, Some(List(Str))], AccessError)
	maybe_strings = |Config(entries), name|
		match Body.find_entry(entries, name) {
			# An omitted optional CustomPlugin `tags` returns None.
			Err(MissingField(_)) => Ok(None)
			# Any lookup type error for `tags` is preserved.
			Err(WrongType(problem)) => Err(WrongType(problem))
			# `tags: ["demo"]` returns Some(["demo"]).
			Ok(StringListValue(values)) => Ok(Some(values))
			# A string stored under `tags` cannot be read as an optional list.
			Ok(StringValue(_)) => Err(WrongType({ expected: StringList, field: name }))
		}

	# CustomPlugin can use this to turn a body diagnostic into user-facing text.
	describe : Diagnostic -> Str
	describe = |diagnostic|
		match diagnostic.kind {
			# Two CustomPlugin `message` fields become `duplicate field 'message'`.
			DuplicateField(name) => "duplicate field '${name}'"
			# A missing colon in CustomPlugin keeps its specific syntax message.
			InvalidSyntax(message) => message
			# An invalid escape in CustomPlugin keeps its string error message.
			InvalidString(message) => message
			# An empty CustomPlugin body reports `missing required field 'message'`.
			MissingField(name) => "missing required field '${name}'"
			# CustomPlugin's undeclared `extra` reports `unknown field 'extra'`.
			UnknownField(name) => "unknown field '${name}'"
			# A non-string hypothetical CustomPlugin tag reports string-only items.
			WrongListItem(field) => "items in field '${field}' must be strings"
			# `message: 1` reports that CustomPlugin's `message` must be a string.
			WrongType({ expected, field }) => "field '${field}' must be ${Body.shape_name(expected)}"
		}

	# CustomPlugin diagnostics use this to name an expected value shape.
	shape_name : ValueShape -> Str
	shape_name = |shape|
		match shape {
			# CustomPlugin's `message` expectation is described as `a string`.
			String => "a string"
			# A hypothetical CustomPlugin `tags` expectation is `a list of strings`.
			StringList => "a list of strings"
		}
}
