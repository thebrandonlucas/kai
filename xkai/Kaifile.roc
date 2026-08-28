# Declarative schemas describe the Kaifile blocks consumed by plugin commands.
import parser.Body

Kaifile := [].{
	Block(name_rule) : {
		fields : List(Body.Field),
		header : Str,
		kind : [DirectBlockHeader, NamedBlockHeader],
		name_rules : List(name_rule),
	}

	block : { fields : List(Body.Field), header : Str } -> Block(rule)
	block = |{ fields, header }| { fields, header, kind: DirectBlockHeader, name_rules: [] }

	named_block : { fields : List(Body.Field), header : Str, name_rules : List(rule) } -> Block(rule)
	named_block = |{ fields, header, name_rules }| { fields, header, kind: NamedBlockHeader, name_rules }

	body : Block(rule) -> Body.Shape
	body = |schema| Body.object(schema.fields)

	block_name : Block(rule) -> Str
	block_name = |schema| Kaifile.header_tokens(schema.header).first() ?? ""

	is_named : Block(rule) -> Bool
	is_named = |schema| schema.kind == NamedBlockHeader

	validate_header : Block(rule) -> Try({}, Str)
	validate_header = |schema| {
		tokens = Kaifile.header_tokens(schema.header)
		valid = match (schema.kind, tokens) {
			(DirectBlockHeader, [literal]) => Kaifile.valid_name(literal)
			(NamedBlockHeader, [literal, slot]) => Kaifile.valid_name(literal) and Kaifile.valid_slot(slot)
			_ => Bool.False
		}
		if valid {
			Ok({})
		} else {
			kind = if schema.kind == NamedBlockHeader "named" else "direct"
			expected = if schema.kind == NamedBlockHeader "one literal token followed by one '<slot>' token" else "one literal token"
			Err("${kind} Kaifile block header '${schema.header}' must be ${expected}")
		}
	}

	header_tokens = |header| Kaifile.collect_tokens(header.to_utf8(), 0, [])
	collect_tokens = |bytes, raw_index, tokens| {
		start = Kaifile.skip_whitespace(bytes, raw_index)
		if start >= bytes.len() {
			tokens
		} else {
			end = Kaifile.find_token_end(bytes, start)
			token = Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""
			Kaifile.collect_tokens(bytes, end, tokens.append(token))
		}
	}

	skip_whitespace = |bytes, index|
		if index < bytes.len() and Kaifile.is_whitespace(bytes.get(index) ?? 0) {
			Kaifile.skip_whitespace(bytes, index + 1)
		} else {
			index
		}
	find_token_end = |bytes, index|
		if index < bytes.len() and !Kaifile.is_whitespace(bytes.get(index) ?? 0) {
			Kaifile.find_token_end(bytes, index + 1)
		} else {
			index
		}

	valid_slot = |slot| {
		bytes = slot.to_utf8()
		bytes.len() >= 3 and
			(bytes.first() ?? 0) == '<' and
				(bytes.last() ?? 0) == '>' and
					Kaifile.valid_name_bytes(bytes.sublist({ start: 1, len: bytes.len() - 2 }))
	}

	valid_name = |name| Kaifile.valid_name_bytes(name.to_utf8())
	valid_name_bytes = |bytes|
		!bytes.is_empty() and List.all(
			bytes,
			|byte|
				!Kaifile.is_whitespace(byte) and
					byte != 0 and
						byte != '"' and
							byte != '#' and
								byte != '{' and
									byte != '}' and
										byte != '<' and
											byte != '>',
		)

	is_whitespace = |byte| byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r'
}
