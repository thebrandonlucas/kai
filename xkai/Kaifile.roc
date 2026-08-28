# Declarative schemas describe the Kaifile blocks consumed by plugin commands.
import parser.Fields

Kaifile := [].{
	ReferenceTarget(name_rule) := {
		fields : List(Fields.Field),
		header : Str,
		kind : [DirectBlockHeader, NamedBlockHeader],
		name_rules : List(name_rule),
		reference_count : U64,
	}

	Field(name_rule) : [
		ReferenceField(
			{
				field : Fields.Field,
				target : ReferenceTarget(name_rule),
			},
		),
		ValueField(Fields.Field),
	]

	BlockSchema(name_rule) : {
		fields : List(Field(name_rule)),
		header : Str,
		kind : [DirectBlockHeader, NamedBlockHeader],
		name_rules : List(name_rule),
	}

	Reference(name_rule) := {
		field : Fields.Field,
		target : ReferenceTarget(name_rule),
	}

	Block(name_rule) : {
		schema : BlockSchema(name_rule),
		selection : [
			ByOptionalArgument(
				{ argument : Str, when_provided : BlockSchema(name_rule) },
			),
			OptionalBlock,
			RequiredBlock,
		],
	}

	required : Str, Fields.ValueShape -> Field(rule)
	required = |name, value| ValueField(Fields.required(name, value))

	optional : Str, Fields.ValueShape -> Field(rule)
	optional = |name, value| ValueField(Fields.optional(name, value))

	required_reference : Str, Block(rule) -> Field(rule)
	required_reference = |name, target|
		ReferenceField({
			field: Fields.required(name, Identifier),
			target: Kaifile.reference_target(target),
		})

	required_quoted_reference : Str, Block(rule) -> Field(rule)
	required_quoted_reference = |name, target|
		ReferenceField({
			field: Fields.required(name, String),
			target: Kaifile.reference_target(target),
		})

	parser_field : Field(rule) -> Fields.Field
	parser_field = |field|
		match field {
			ReferenceField(reference) => reference.field
			ValueField(value_field) => value_field
		}

	references : Block(rule) -> List(Reference(rule))
	references = |schema_block|
		Kaifile.collect_references(schema_block.schema.fields, [])

	collect_references : List(Field(rule)),
	List(Reference(rule)) -> List(
		Reference(rule),
	)
	collect_references = |fields, collected|
		match fields {
			[] => collected
			[first, .. as rest] =>
				match first {
					ReferenceField(reference) =>
						Kaifile.collect_references(rest, collected.append(reference))
					ValueField(_) => Kaifile.collect_references(rest, collected)
				}
			}

	block : { fields : List(Field(rule)), header : Str } -> Block(rule)
	block = |{ fields, header }| {
		schema: {
			fields,
			header,
			kind: DirectBlockHeader,
			name_rules: [],
		},
		selection: RequiredBlock,
	}

	named_block :
		{
			fields : List(Field(rule)),
			header : Str,
			name_rules : List(rule),
		} -> Block(rule)
	named_block = |{ fields, header, name_rules }| {
		schema: { fields, header, kind: NamedBlockHeader, name_rules },
		selection: RequiredBlock,
	}

	optional_block : Block(rule) -> Block(rule)
	optional_block = |schema_block| {
		schema: schema_block.schema,
		selection: OptionalBlock,
	}

	by_optional_argument :
		{
			argument : Str,
			when_omitted : Block(rule),
			when_provided : Block(rule),
		} -> Block(rule)
	by_optional_argument = |{ argument, when_omitted, when_provided }| {
		schema: when_omitted.schema,
		selection: ByOptionalArgument({
			argument,
			when_provided: when_provided.schema,
		}),
	}

	from_schema : BlockSchema(rule) -> Block(rule)
	from_schema = |schema| { schema, selection: RequiredBlock }

	from_reference_target : ReferenceTarget(rule) -> Block(rule)
	from_reference_target = |target| {
		schema: {
			fields: target.fields.map(|field| ValueField(field)),
			header: target.header,
			kind: target.kind,
			name_rules: target.name_rules,
		},
		selection: RequiredBlock,
	}

	reference_target : Block(rule) -> ReferenceTarget(rule)
	reference_target = |target| {
		fields: target.schema.fields.map(Kaifile.parser_field),
		header: target.schema.header,
		kind: target.schema.kind,
		name_rules: target.schema.name_rules,
		reference_count: Kaifile.references(target).len(),
	}

	body : Block(rule) -> Fields.Shape
	body = |schema_block|
		Fields.object(schema_block.schema.fields.map(Kaifile.parser_field))

	block_name : Block(rule) -> Str
	block_name = |schema_block|
		Kaifile.header_tokens(schema_block.schema.header).first() ?? ""

	header_argument : Block(rule) -> [HeaderArgument(Str), NoHeaderArgument]
	header_argument = |schema_block|
		match Kaifile.header_tokens(schema_block.schema.header) {
			[_, slot] => {
				bytes = slot.to_utf8()
				name = Str.from_utf8(
					bytes.sublist({ start: 1, len: bytes.len() - 2 }),
				) ?? ""
				HeaderArgument(name)
			}
			_ => NoHeaderArgument
		}

	is_named : Block(rule) -> Bool
	is_named = |schema_block| schema_block.schema.kind == NamedBlockHeader

	name_rules : Block(rule) -> List(rule)
	name_rules = |schema_block| schema_block.schema.name_rules

	validate_header : Block(rule) -> Try({}, Str)
	validate_header = |schema_block| {
		schema = schema_block.schema
		tokens = Kaifile.header_tokens(schema.header)
		valid = match (schema.kind, tokens) {
			(DirectBlockHeader, [literal]) => Kaifile.valid_name(literal)
			(NamedBlockHeader, [literal, slot]) =>
				Kaifile.valid_name(literal) and Kaifile.valid_slot(slot)
			_ => Bool.False
		}
		if valid {
			Ok({})
		} else {
			kind = if schema.kind == NamedBlockHeader "named" else "direct"
			expected = if schema.kind == NamedBlockHeader {
				"one literal token followed by one '<slot>' token"
			} else {
				"one literal token"
			}
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

	is_whitespace = |byte|
		byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r'
}
