# Parse fields in a config block
Fields := [].{

	ValueShape : [Identifier, String, StringList]
	Presence : [Optional, Required]
	Field := {
		name : Str,
		presence : Presence,
		value : ValueShape,
	}
	Shape : [Object(List(Field))]

	Value : [StringValue(Str), StringListValue(List(Str))]
	Entry := { name : Str, value : Value }
	ParsedFields : [Config(List(Entry))]

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
	Diagnostic := {
		byte_offset : U64,
		kind : DiagnosticKind,
	}

	AccessError : [
		MissingField(Str),
		WrongType(
			{
				expected : ValueShape,
				field : Str,
			},
		),
	]

	object : List(Field) -> Shape
	object = |fields| Object(fields)

	required : Str, ValueShape -> Field
	required = |name, value| { name, presence: Required, value }

	optional : Str, ValueShape -> Field
	optional = |name, value| { name, presence: Optional, value }

	empty : ParsedFields
	empty = Config([])

	parse : Shape, Str -> Try(ParsedFields, Diagnostic)
	parse = |shape, body_text| {
		fields = match shape {
			Object(object_fields) => object_fields
		}
		bytes = body_text.to_utf8()
		parsed = Fields.parse_fields(
			bytes,
			Fields.skip_trivia(bytes, 0),
			fields,
			[],
		)?
		Fields.require_fields(
			fields,
			parsed.entries,
			bytes.len(),
		)?
		Ok(Config(parsed.entries))
	}

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
		start = Fields.skip_trivia(bytes, index)
		if start >= bytes.len() {
			Ok({ entries, rest: start })
		} else {
			name_result = Fields.parse_name(bytes, start)?
			name = name_result.name
			field = Fields.find_field(fields, name) ? |_| {
				byte_offset: start,
				kind: UnknownField(name),
			}
			if Fields.has_entry(entries, name) {
				Err({
					byte_offset: start,
					kind: DuplicateField(name),
				})
			} else {
				colon_index = Fields.skip_trivia(bytes, name_result.rest)
				if Fields.byte_at(bytes, colon_index) != ':' {
					Err({
						byte_offset: colon_index,
						kind: InvalidSyntax("expected ':' after field '${name}'"),
					})
				} else {
					value_start = Fields.skip_trivia(bytes, colon_index + 1)
					parsed_value = Fields.parse_value(bytes, value_start, field)?
					Fields.parse_fields(
						bytes,
						parsed_value.rest,
						fields,
						entries.append({ name, value: parsed_value.value }),
					)
				}
			}
		}
	}

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
			Identifier => {
				parsed = Fields.parse_identifier(bytes, index, field.name)?
				Ok({ rest: parsed.rest, value: StringValue(parsed.value) })
			}
			String =>
				if Fields.byte_at(bytes, index) != '"' {
					Err({
						byte_offset: index,
						kind: WrongType({
							expected: String,
							field: field.name,
						}),
					})
				} else {
					parsed = Fields.parse_string(bytes, index)?
					Ok({ rest: parsed.rest, value: StringValue(parsed.value) })
				}
			StringList =>
				if Fields.byte_at(bytes, index) != '[' {
					Err({
						byte_offset: index,
						kind: WrongType({
							expected: StringList,
							field: field.name,
						}),
					})
				} else {
					parsed = Fields.parse_string_list(
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

	parse_identifier : List(U8),
	U64,
	Str -> Try(
		{ rest : U64, value : Str },
		Diagnostic,
	)
	parse_identifier = |bytes, start, field_name|
		if !Fields.is_name_start(Fields.byte_at(bytes, start)) {
			Err({
				byte_offset: start,
				kind: WrongType({ expected: Identifier, field: field_name }),
			})
		} else {
			end = Fields.find_identifier_end(bytes, start + 1)
			value = Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""
			Ok({ rest: end, value })
		}

	find_identifier_end : List(U8), U64 -> U64
	find_identifier_end = |bytes, index|
		if index < bytes.len() and
			Fields.is_identifier_continue(Fields.byte_at(bytes, index)) {
			Fields.find_identifier_end(bytes, index + 1)
		} else {
			index
		}

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
		start = Fields.skip_trivia(bytes, index)
		byte = Fields.byte_at(bytes, start)
		if start >= bytes.len() {
			Err({
				byte_offset: start,
				kind: InvalidSyntax("unterminated list in field '${field_name}'"),
			})
		} else if byte == ']' and allow_end {
			Ok({ rest: start + 1, values })
		} else if byte == ']' {
			Err({
				byte_offset: start,
				kind: InvalidSyntax("expected a string after ',' in field '${field_name}'"),
			})
		} else if byte != '"' {
			Err({ byte_offset: start, kind: WrongListItem(field_name) })
		} else {
			parsed = Fields.parse_string(bytes, start)?
			next = Fields.skip_trivia(bytes, parsed.rest)
			next_byte = Fields.byte_at(bytes, next)
			if next_byte == ',' {
				Fields.parse_string_list(
					bytes,
					next + 1,
					field_name,
					values.append(parsed.value),
					Bool.False,
				)
			} else if next_byte == ']' {
				Ok({ rest: next + 1, values: values.append(parsed.value) })
			} else {
				Err({
					byte_offset: next,
					kind: InvalidSyntax(
						"expected ',' or ']' in field '${field_name}'",
					),
				})
			}
		}
	}

	parse_string : List(U8), U64 -> Try({ rest : U64, value : Str }, Diagnostic)
	parse_string = |bytes, start| {
		end = Fields.find_string_end(bytes, start + 1, Bool.False)?
		raw = Str.from_utf8(bytes.sublist({ start, len: end - start + 1 })) ?? ""
		decoded = Json.parse(raw)
		match decoded {
			Ok(value) => Ok({ rest: end + 1, value })
			Err(_) => Err({ byte_offset: start, kind: InvalidString("invalid string") })
		}
	}

	find_string_end : List(U8), U64, Bool -> Try(U64, Diagnostic)
	find_string_end = |bytes, index, escaped|
		if index >= bytes.len() {
			Err({ byte_offset: index, kind: InvalidString("unterminated string") })
		} else {
			byte = Fields.byte_at(bytes, index)
			if escaped {
				Fields.find_string_end(bytes, index + 1, Bool.False)
			} else if byte == '\\' {
				Fields.find_string_end(bytes, index + 1, Bool.True)
			} else if byte == '"' {
				Ok(index)
			} else {
				Fields.find_string_end(bytes, index + 1, Bool.False)
			}
		}

	parse_name : List(U8), U64 -> Try({ name : Str, rest : U64 }, Diagnostic)
	parse_name = |bytes, start| {
		first = Fields.byte_at(bytes, start)
		if !Fields.is_name_start(first) {
			Err({ byte_offset: start, kind: InvalidSyntax("expected a field name") })
		} else {
			end = Fields.find_name_end(bytes, start + 1)
			name = Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""
			Ok({ name, rest: end })
		}
	}

	find_name_end : List(U8), U64 -> U64
	find_name_end = |bytes, index|
		if index < bytes.len() and
			Fields.is_name_continue(Fields.byte_at(bytes, index)) {
			Fields.find_name_end(bytes, index + 1)
		} else {
			index
		}

	skip_trivia : List(U8), U64 -> U64
	skip_trivia = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Fields.byte_at(bytes, index)
			if Fields.is_whitespace(byte) {
				Fields.skip_trivia(bytes, index + 1)
			} else if byte == '#' {
				Fields.skip_trivia(bytes, Fields.skip_comment(bytes, index + 1))
			} else {
				index
			}
		}

	skip_comment : List(U8), U64 -> U64
	skip_comment = |bytes, index|
		if index >= bytes.len() or Fields.byte_at(bytes, index) == '\n' {
			index
		} else {
			Fields.skip_comment(bytes, index + 1)
		}

	is_whitespace : U8 -> Bool
	is_whitespace = |byte|
		byte == ' ' or
			byte == '\t' or
				byte == '\n' or
					byte == '\r'

	is_name_start : U8 -> Bool
	is_name_start = |byte|
		(byte >= 'A' and byte <= 'Z') or
			(byte >= 'a' and byte <= 'z') or
				byte == '_'

	is_name_continue : U8 -> Bool
	is_name_continue = |byte|
		Fields.is_name_start(byte) or
			(byte >= '0' and byte <= '9')

	is_identifier_continue : U8 -> Bool
	is_identifier_continue = |byte|
		Fields.is_name_continue(byte) or byte == '-' or byte == '.'

	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index| bytes.get(index) ?? 0

	find_field : List(Field), Str -> Try(Field, [NotFound])
	find_field = |fields, name|
		match fields {
			[] => Err(NotFound)
			[first, .. as rest] =>
				if first.name == name {
					Ok(first)
				} else {
					Fields.find_field(rest, name)
				}
			}

	has_entry : List(Entry), Str -> Bool
	has_entry = |entries, name|
		match entries {
			[] => Bool.False
			[first, .. as rest] => first.name == name or Fields.has_entry(rest, name)
		}

	require_fields : List(Field), List(Entry), U64 -> Try({}, Diagnostic)
	require_fields = |fields, entries, end|
		match fields {
			[] => Ok({})
			[first, .. as rest] =>
				if first.presence == Required and !Fields.has_entry(entries, first.name) {
					Err({ byte_offset: end, kind: MissingField(first.name) })
				} else {
					Fields.require_fields(rest, entries, end)
				}
			}

	find_entry : List(Entry), Str -> Try(Value, AccessError)
	find_entry = |entries, name|
		match entries {
			[] => Err(MissingField(name))
			[first, .. as rest] =>
				if first.name == name {
					Ok(first.value)
				} else {
					Fields.find_entry(rest, name)
				}
			}

	get_string : ParsedFields, Str -> Try(Str, AccessError)
	get_string = |Config(entries), name|
		match Fields.find_entry(entries, name)? {
			StringValue(value) => Ok(value)
			StringListValue(_) => Err(WrongType({ expected: String, field: name }))
		}

	get_strings : ParsedFields, Str -> Try(List(Str), AccessError)
	get_strings = |Config(entries), name|
		match Fields.find_entry(entries, name)? {
			StringListValue(values) => Ok(values)
			StringValue(_) => Err(WrongType({ expected: StringList, field: name }))
		}

	maybe_string : ParsedFields, Str -> Try([None, Some(Str)], AccessError)
	maybe_string = |Config(entries), name|
		match Fields.find_entry(entries, name) {
			Err(MissingField(_)) => Ok(None)
			Err(WrongType(problem)) => Err(WrongType(problem))
			Ok(StringValue(value)) => Ok(Some(value))
			Ok(StringListValue(_)) => Err(WrongType({ expected: String, field: name }))
		}

	maybe_strings : ParsedFields, Str -> Try([None, Some(List(Str))], AccessError)
	maybe_strings = |Config(entries), name|
		match Fields.find_entry(entries, name) {
			Err(MissingField(_)) => Ok(None)
			Err(WrongType(problem)) => Err(WrongType(problem))
			Ok(StringListValue(values)) => Ok(Some(values))
			Ok(StringValue(_)) => Err(WrongType({ expected: StringList, field: name }))
		}

	describe : Diagnostic -> Str
	describe = |diagnostic|
		match diagnostic.kind {
			DuplicateField(name) => "duplicate field '${name}'"
			InvalidSyntax(message) => message
			InvalidString(message) => message
			MissingField(name) => "missing required field '${name}'"
			UnknownField(name) => "unknown field '${name}'"
			WrongListItem(field) => "items in field '${field}' must be strings"
			WrongType({ expected, field }) => Str.join_with(
				[
					"field '${field}' must be",
					Fields.shape_name(expected),
				],
				" ",
			)
		}

	shape_name : ValueShape -> Str
	shape_name = |shape|
		match shape {
			Identifier => "an identifier"
			String => "a string"
			StringList => "a list of strings"
		}
}
