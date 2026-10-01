## An S-expression format for any value whose type has `encoder_for` and
## `parser_for`, derived or hand-written.
##
## | Roc value              | S-expression              |
## |------------------------|---------------------------|
## | `"text"`               | `"text"`                  |
## | `42`                   | `42`                      |
## | `True` (Bool)          | `true`                    |
## | `[a, b]`               | `(a b)`                   |
## | `{ x: a, y: b }`       | `((x a) (y b))`           |
## | `Tag`                  | `Tag`                     |
## | `Tag(a, b)`            | `(Tag a b)`               |
##
## A trailing `_` on a Roc field name is dropped in the text, so fields
## named after Roc keywords (`packages_`, `requires_`) read naturally.
##
## Nested records are indented one tab per level, so the text diffs cleanly.
Sexpr :: [].{

	## Serialise a value as S-expression text.
	to_str : a -> Str
		where [a.encoder_for : Format -> (a, Out -> Try(Out, []))]
	to_str = |value| {
		Shape : a
		encode = Shape.encoder_for(Format.Default)
		Ok(written) = encode(value, Out.{ text: "", depth: 0 })
		written.text
	}

	## Parse S-expression text into a value.
	parse : Str -> Try(a, [InvalidSexpr(Str), ..errs])
		where [
			a.parser_for : Format -> (
				List(Token) -> Try(
					{ value : a, rest : List(Token) },
					[InvalidSexpr(Str), ..errs],
				)),
		]
	parse = |text| {
		Shape : a
		tokens =
			match tokenize(text) {
				Ok(list) => list
				Err(InvalidSexpr(msg)) => return Err(InvalidSexpr(msg))
			}
		parse_shape = Shape.parser_for(Format.Default)
		parsed = parse_shape(tokens)?
		match parsed.rest {
			[] => Ok(parsed.value)
			[token, ..] => Err(
				InvalidSexpr("unexpected ${describe(token)} after the value"),
			)
		}
	}

	## One lexical token.
	Token := [Open, Close, Text(Str), Symbol(Str), Number(Str)].{
		is_eq : _
	}

	## Encoder output: the text so far and the current nesting depth.
	Out := { text : Str, depth : U64 }

	## The format itself; its methods drive derived encoders and parsers.
	Format := [Default].{

		## Encoding

		encode_str : Str, Out -> Try(Out, _never_fails)
		encode_str = |value, out| Ok(append(out, quote(value)))

		encode_bool : Bool, Out -> Try(Out, _never_fails)
		encode_bool = |value, out| Ok(append(out, if value "true" else "false"))

		encode_u8 : U8, Out -> Try(Out, _never_fails)
		encode_u8 = |value, out| Ok(append(out, value.to_str()))

		encode_u16 : U16, Out -> Try(Out, _never_fails)
		encode_u16 = |value, out| Ok(append(out, value.to_str()))

		encode_u32 : U32, Out -> Try(Out, _never_fails)
		encode_u32 = |value, out| Ok(append(out, value.to_str()))

		encode_u64 : U64, Out -> Try(Out, _never_fails)
		encode_u64 = |value, out| Ok(append(out, value.to_str()))

		encode_i64 : I64, Out -> Try(Out, _never_fails)
		encode_i64 = |value, out| Ok(append(out, value.to_str()))

		encode_list :
			Out,
			U64,
			(Out, (Out, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)) ->
				Try(
					Out,
					err,
				)
		encode_list = |out, _, write_items| {
			finished = write_items(append(out, "("), write_item)?
			Ok(append(finished, ")"))
		}

		encode_tuple :
			Out,
			U64,
			(Out, (Out, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)) ->
				Try(
					Out,
					err,
				)
		encode_tuple = |out, count, write_items|
			Format.encode_list(out, count, write_items)

		encode_record :
			Out,
			U64,
			(
				Out,
				(Out, Str, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(
					Out,
					err,
				)) ->
					Try(Out, err)
		encode_record = |out, _, write_fields| {
			started = { ..append(out, "("), depth: out.depth + 1 }
			finished = write_fields(started, write_field)?
			Ok(append({ ..finished, depth: out.depth }, ")"))
		}

		encode_tag :
			Out,
			Str,
			U64,
			(Out, (Out, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)) ->
				Try(
					Out,
					err,
				)
		encode_tag = |out, tag, count, write_payloads|
			if count == 0 {
				Ok(append(out, tag))
			} else {
				finished = write_payloads(append(out, "(${tag}"), write_payload)?
				Ok(append(finished, ")"))
			}

		## Parsing

		rename_field : Format, Str -> Str
		rename_field = |_, name| wire_name(name)

		parse_str :
			Format,
			List(Token) ->
				Try(
					{ value : Str, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_str = |_, tokens|
			match tokens {
				[Text(value), .. as rest] => Ok({ value, rest })
				_ => Err(expected("a string", tokens))
			}

		parse_bool :
			Format,
			List(Token) ->
				Try(
					{ value : Bool, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_bool = |_, tokens|
			match tokens {
				[Symbol("true"), .. as rest] => Ok({ value: True, rest })
				[Symbol("false"), .. as rest] => Ok({ value: False, rest })
				_ => Err(expected("true or false", tokens))
			}

		parse_u8 :
			Format,
			List(Token) ->
				Try(
					{ value : U8, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_u8 = |_, tokens| number(tokens, U8.from_str)

		parse_u16 :
			Format,
			List(Token) ->
				Try(
					{ value : U16, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_u16 = |_, tokens| number(tokens, U16.from_str)

		parse_u32 :
			Format,
			List(Token) ->
				Try(
					{ value : U32, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_u32 = |_, tokens| number(tokens, U32.from_str)

		parse_u64 :
			Format,
			List(Token) ->
				Try(
					{ value : U64, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_u64 = |_, tokens| number(tokens, U64.from_str)

		parse_i64 :
			Format,
			List(Token) ->
				Try(
					{ value : I64, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_i64 = |_, tokens| number(tokens, I64.from_str)

		parse_list_start :
			Format,
			List(Token) ->
				Try(
					[Counted({ len : U64, rest : List(Token) }), Uncounted(List(Token))],
					[InvalidSexpr(Str), ..others],
				)
		parse_list_start = |_, tokens| open(tokens).map_ok(|rest| Uncounted(rest))

		parse_list_next :
			Format,
			List(Token) ->
				Try(
					[Item(List(Token)), Done(List(Token))],
					[InvalidSexpr(Str), ..others],
				)
		parse_list_next = |_, tokens|
			match tokens {
				[Close, .. as rest] => Ok(Done(rest))
				[] => Err(expected("a list item or )", tokens))
				_ => Ok(Item(tokens))
			}

		parse_list_after_item :
			Format,
			List(Token) ->
				Try(
					[Continue(List(Token)), Done(List(Token))],
					[InvalidSexpr(Str), ..others],
				)
		parse_list_after_item = |_, tokens|
			match tokens {
				[Close, .. as rest] => Ok(Done(rest))
				[] => Err(expected("a list item or )", tokens))
				_ => Ok(Continue(tokens))
			}

		parse_record_start :
			Format,
			List(Token) ->
				Try(
					[Counted({ len : U64, rest : List(Token) }), Uncounted(List(Token))],
					[InvalidSexpr(Str), ..others],
				)
		parse_record_start = |_, tokens| open(tokens).map_ok(|rest| Uncounted(rest))

		parse_record_field : Format,
		Encoding.FieldName.FieldNames(_shape),
		List(Token) -> Try(
			[
				Field({ field : Encoding.FieldName(_shape), rest : List(Token) }),
				TryField({ name : Str, rest : List(Token) }),
				TryFieldCaseless({ name : Str, rest : List(Token) }),
				Continue(List(Token)),
				Done(List(Token)),
			],
			[InvalidSexpr(Str), ..others],
		)
		parse_record_field = |_, _, tokens|
			match tokens {
				[Close, .. as rest] => Ok(Done(rest))
				[Open, Symbol(name), .. as rest] => Ok(TryField({ name, rest }))
				_ => Err(expected("(field value) or )", tokens))
			}

		parse_record_after_field :
			Format,
			List(Token) ->
				Try(
					[Continue(List(Token)), Done(List(Token))],
					[InvalidSexpr(Str), ..others],
				)
		parse_record_after_field = |_, tokens|
			match tokens {
				[Close, Close, .. as rest] => Ok(Done(rest))
				[Close, .. as rest] => Ok(Continue(rest))
				_ => Err(expected(") after a field value", tokens))
			}

		skip_record_field :
			Format,
			List(Token) ->
				Try(
					List(Token),
					[InvalidSexpr(Str), ..others],
				)
		skip_record_field = |_, tokens| skip_value(tokens)

		invalid_value : Format, List(Token) -> [InvalidSexpr(Str)]
		invalid_value = |_, tokens| expected("a valid value", tokens)

		parse_tag_union :
			Format,
			Encoding.ParseTagUnionSpec(a),
			List(Token) ->
				Try(
					{ value : a, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				)
		parse_tag_union = |format, spec, tokens|
			match tokens {
				[Symbol(tag), .. as rest] =>
					Encoding.ParseTagUnionSpec.parse(
						spec,
						{
							tag,
							encoding: format,
							state: rest,
							start_payloads: |state, count|
								if count == 0 {
									Ok(state)
								} else {
									Err(
										InvalidSexpr(
											"tag ${tag} needs ${count.to_str()} payload(s); write (${tag} ...)",
										),
									)
								},
							next_payload: |state, _, _| Ok(state),
							finish_payloads: |state, _| Ok(state),
							missing: InvalidSexpr("unknown tag ${tag}"),
						},
					)
				[Open, Symbol(tag), .. as rest] =>
					Encoding.ParseTagUnionSpec.parse(
						spec,
						{
							tag,
							encoding: format,
							state: rest,
							start_payloads: |state, _| Ok(state),
							next_payload: |state, _, _| Ok(state),
							finish_payloads: |state, _|
								match state {
									[Close, .. as after] => Ok(after)
									_ => Err(expected(") after the payloads of ${tag}", state))
								},
							missing: InvalidSexpr("unknown tag ${tag}"),
						},
					)
				_ => Err(expected("a tag", tokens))
			}
	}

	## Split text into tokens. `;` starts a comment that runs to the end of the
	## line.
	tokenize : Str -> Try(List(Token), [InvalidSexpr(Str)])
	tokenize = |text| {
		bytes = text.to_utf8()
		var $tokens = []
		var $i = 0
		len = bytes.len()
		while $i < len {
			byte = bytes.get($i) ?? 0
			if byte == '(' {
				$tokens = $tokens.append(Open)
				$i = $i + 1
			} else if byte == ')' {
				$tokens = $tokens.append(Close)
				$i = $i + 1
			} else if byte == ' ' or byte == '\n' or byte == '\t' or byte == '\r' {
				$i = $i + 1
			} else if byte == ';' {
				while $i < len and (bytes.get($i) ?? 0) != '\n' {
					$i = $i + 1
				}
			} else if byte == '"' {
				read = read_string(bytes, $i + 1)?
				$tokens = $tokens.append(Text(read.value))
				$i = read.next
			} else {
				start = $i
				while $i < len and !is_delimiter(bytes.get($i) ?? ' ') {
					$i = $i + 1
				}
				word = Str.from_utf8_lossy(bytes.sublist({ start, len: $i - start }))
				first = bytes.get(start) ?? 0
				is_number = (first >= '0' and first <= '9') or
					(first == '-' and word != "-")
				$tokens = $tokens.append(if is_number Number(word) else Symbol(word))
			}
		}
		Ok($tokens)
	}

	is_delimiter : U8 -> Bool
	is_delimiter = |b|
		b == '(' or b == ')' or b == ' ' or b == '\n' or b == '\t' or b == '\r' or
			b == '"' or b == ';'

	read_string :
		List(U8),
		U64 ->
			Try(
				{ value : Str, next : U64 },
				[InvalidSexpr(Str)],
			)
	read_string = |bytes, from| {
		var $out = []
		var $i = from
		len = bytes.len()
		while $i < len {
			byte = bytes.get($i) ?? 0
			if byte == '"' {
				return match Str.from_utf8($out) {
					Ok(value) => Ok({ value, next: $i + 1 })
					Err(_) => Err(InvalidSexpr("string is not valid UTF-8"))
				}
			} else if byte == '\\' {
				escaped = bytes.get($i + 1) ?? 0
				decoded =
					if escaped == 'n' {
						'\n'
					} else if escaped == 't' {
						'\t'
					} else if escaped == '"' or escaped == '\\' {
						escaped
					} else {
						return Err(InvalidSexpr("unknown escape in string"))
					}
				$out = $out.append(decoded)
				$i = $i + 2
			} else {
				$out = $out.append(byte)
				$i = $i + 1
			}
		}
		Err(InvalidSexpr("unterminated string"))
	}

	quote : Str -> Str
	quote = |value| {
		escaped = value
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("\n", "\\n")
			.replace_each("\t", "\\t")
		"\"${escaped}\""
	}

	append : Out, Str -> Out
	append = |out, text| { ..out, text: Str.concat(out.text, text) }

	## Separates items with a space, except straight after an open paren.
	separate : Out -> Out
	separate = |out| if out.text.ends_with("(") out else append(out, " ")

	write_item : Out, (Out -> Try(Out, err)) -> Try(Out, err)
	write_item = |out, write_value| write_value(separate(out))

	write_payload : Out, (Out -> Try(Out, err)) -> Try(Out, err)
	write_payload = |out, write_value| write_value(append(out, " "))

	write_field : Out, Str, (Out -> Try(Out, err)) -> Try(Out, err)
	write_field = |out, name, write_value| {
		indent = Str.repeat("\t", out.depth)
		written = write_value(append(out, "\n${indent}(${wire_name(name)} "))?
		Ok(append(written, ")"))
	}

	## A field's name in the text: the Roc name without a trailing `_`, so a
	## field can be called `packages_` in Roc (where `packages` is a keyword)
	## and `packages` on the wire.
	wire_name : Str -> Str
	wire_name = |name|
		if name.ends_with("_") and name != "_" {
			Str.from_utf8_lossy(name.to_utf8().drop_last(1))
		} else {
			name
		}

	open : List(Token) -> Try(List(Token), [InvalidSexpr(Str), ..others])
	open = |tokens|
		match tokens {
			[Open, .. as rest] => Ok(rest)
			_ => Err(expected("(", tokens))
		}

	number :
		List(Token),
		(Str -> Try(n, _)) ->
			Try(
				{ value : n, rest : List(Token) },
				[InvalidSexpr(Str), ..others],
			)
	number = |tokens, from_str|
		match tokens {
			[Number(raw), .. as rest] =>
				match from_str(raw) {
					Ok(value) => Ok({ value, rest })
					Err(_) => Err(InvalidSexpr("number out of range: ${raw}"))
				}
			_ => Err(expected("a number", tokens))
		}

	## Skip one complete value, used for record fields the target type lacks.
	skip_value : List(Token) -> Try(List(Token), [InvalidSexpr(Str), ..others])
	skip_value = |tokens| {
		var $depth = 0
		var $rest = tokens
		while True {
			match $rest {
				[] => return Err(expected("a value", tokens))
				[Open, .. as more] => {
					$depth = $depth + 1
					$rest = more
				}
				[Close, .. as more] => {
					if $depth == 0 {
						return Err(expected("a value", tokens))
					}
					$depth = $depth - 1
					$rest = more
					if $depth == 0 {
						return Ok($rest)
					}
				}
				[_, .. as more] => {
					$rest = more
					if $depth == 0 {
						return Ok($rest)
					}
				}
			}
		}
		Ok($rest)
	}

	expected : Str, List(Token) -> [InvalidSexpr(Str), ..others]
	expected = |what, tokens|
		match tokens {
			[token, ..] => InvalidSexpr("expected ${what}, found ${describe(token)}")
			[] => InvalidSexpr("expected ${what}, found end of input")
		}

	describe : Token -> Str
	describe = |token|
		match token {
			Open => "("
			Close => ")"
			Text(value) => quote(value)
			Symbol(name) => name
			Number(raw) => raw
		}
}

# Strings are quoted with embedded quotes backslash-escaped.
expect Sexpr.to_str("a \"b\"") == "\"a \\\"b\\\"\""
# Lists render as space-separated items inside one pair of parentheses.
expect Sexpr.to_str(["x", "y"]) == "(\"x\" \"y\")"
# Record fields render one per line, indented a tab per nesting level.
expect Sexpr.to_str({ a: 1.U64, b: "z" }) == "(\n\t(a 1)\n\t(b \"z\"))"

# A parenthesized list of strings parses back into a Roc list.
expect {
	parsed : Try(List(Str), _)
	parsed = Sexpr.parse("(\"x\" \"y\")")
	parsed == Ok(["x", "y"])
}

# Derived codecs round-trip records holding tags with and without payloads.
expect {
	value = {
		name: "demo",
		tags: [Plain, WithArgs("a", 2.U64)],
		nested: { ok: True },
	}
	Sexpr.parse(Sexpr.to_str(value)) == Ok(value)
}

# Fields the target record lacks are skipped, including nested values.
expect {
	parsed : Try({ a : U64 }, _)
	parsed = Sexpr.parse("((a 1) (extra (x y)))")
	parsed == Ok({ a: 1 })
}

# An unclosed list is rejected instead of being accepted as complete.
expect {
	parsed : Try(List(Str), _)
	parsed = Sexpr.parse("(\"x\"")
	parsed.is_err()
}

# A trailing underscore on keyword-named fields is dropped on the wire.
expect {
	value : { packages_ : List(Str), requires_ : List(Str) }
	value = { packages_: ["a"], requires_: [] }
	text = Sexpr.to_str(value)
	text.contains("(packages (\"a\"))") and
		text.contains("(requires ())") and
			Sexpr.parse(text) == Ok(value)
}
