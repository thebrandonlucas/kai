# Generic tagged values carried by the IR for backend-specific data.
import Sexpr exposing [Format, Token]

## A generic, JSON-like value, used for backend-specific data in the IR
## (`extensions` and `raw`). In S-expression form every value is tagged:
## `(Str "x")`, `(Int -3)`, `(Bool true)`, `(List (...))`,
## `(Attrs (((name "k") (value ...)) ...))`.
##
## `parser_for` is hand-written so that parsing rejects nesting deeper than
## `max_depth`.
Value := [
	Str(Str),
	Int(I64),
	Bool(Bool),
	List(List(Value)),
	Attrs(List({ name : Str, value : Value })),
].{
	is_eq : _

	encoder_for : _

	parser_for :
		Format ->
			(
				List(Token) -> Try(
					{ value : Value, rest : List(Token) },
					[InvalidSexpr(Str), ..others],
				))
	parser_for = |_| |tokens| parse_at(tokens, 0)

	## The deepest nesting `parser_for` accepts.
	max_depth : U64
	max_depth = 64

	parse_at :
		List(Token),
		U64 ->
			Try(
				{ value : Value, rest : List(Token) },
				[InvalidSexpr(Str), ..others],
			)
	parse_at = |tokens, depth| {
		if depth >= max_depth {
			return Err(
				InvalidSexpr(
					"value nested deeper than ${max_depth.to_str()} levels",
				),
			)
		}
		match tokens {
			[Open, Symbol("Str"), .. as rest] => {
				p = Format.parse_str(Format.Default, rest)?
				close(Str(p.value), p.rest)
			}
			[Open, Symbol("Int"), .. as rest] => {
				p = Format.parse_i64(Format.Default, rest)?
				close(Int(p.value), p.rest)
			}
			[Open, Symbol("Bool"), .. as rest] => {
				p = Format.parse_bool(Format.Default, rest)?
				close(Bool(p.value), p.rest)
			}
			[Open, Symbol("List"), Open, .. as rest] => {
				var $items = []
				var $more = rest
				while True {
					match $more {
						[Close, .. as after] => return close(List($items), after)
						_ => {
							p = parse_at($more, depth + 1)?
							$items = $items.append(p.value)
							$more = p.rest
						}
					}
				}
				Err(InvalidSexpr("unreachable"))
			}
			[Open, Symbol("Attrs"), Open, .. as rest] => {
				var $attrs = []
				var $more = rest
				while True {
					match $more {
						[Close, .. as after] => return close(Attrs($attrs), after)
						_ => {
							p = parse_attr($more, depth + 1)?
							$attrs = $attrs.append(p.value)
							$more = p.rest
						}
					}
				}
				Err(InvalidSexpr("unreachable"))
			}
			[Open, Symbol(tag), ..] => Err(InvalidSexpr("unknown Value tag ${tag}"))
			_ => Err(InvalidSexpr("expected a Value such as (Str \"...\")"))
		}
	}

	parse_attr :
		List(Token),
		U64 ->
			Try(
				{ value : { name : Str, value : Value }, rest : List(Token) },
				[InvalidSexpr(Str), ..others],
			)
	parse_attr = |tokens, depth| {
		var $name = Err(Missing)
		var $value = Err(Missing)
		var $more =
			match tokens {
				[Open, .. as rest] => rest
				_ => return Err(
					InvalidSexpr("expected an attribute ((name ...) (value ...))"),
				)
			}
		while True {
			match $more {
				[Close, .. as after] =>
					return match ($name, $value) {
						(Ok(name), Ok(value)) => Ok({ value: { name, value }, rest: after })
						(Err(_), _) => Err(InvalidSexpr("attribute is missing its name"))
						_ => Err(InvalidSexpr("attribute is missing its value"))
					}
				[Open, Symbol("name"), .. as rest] => {
					p = Format.parse_str(Format.Default, rest)?
					$name = Ok(p.value)
					$more = field_end(p.rest)?
				}
				[Open, Symbol("value"), .. as rest] => {
					p = parse_at(rest, depth)?
					$value = Ok(p.value)
					$more = field_end(p.rest)?
				}
				[Open, Symbol(_), .. as rest] => {
					skipped = Sexpr.skip_value(rest)?
					$more = field_end(skipped)?
				}
				_ => return Err(InvalidSexpr("expected (field value) or ) in an attribute"))
			}
		}
		Err(InvalidSexpr("unreachable"))
	}

	close :
		Value,
		List(Token) ->
			Try(
				{ value : Value, rest : List(Token) },
				[InvalidSexpr(Str), ..others],
			)
	close = |value, tokens|
		match tokens {
			[Close, .. as rest] => Ok({ value, rest })
			_ => Err(InvalidSexpr("expected ) after a Value"))
		}

	field_end : List(Token) -> Try(List(Token), [InvalidSexpr(Str), ..others])
	field_end = |tokens|
		match tokens {
			[Close, .. as rest] => Ok(rest)
			_ => Err(InvalidSexpr("expected ) after a field value"))
		}
}

sample : Value
sample = Value.Attrs([
	{
		name: "x",
		value: Value.List(
			[Value.Int(-3), Value.Bool(True), Value.Str("s"), Value.List([])],
		),
	},
	{ name: "y", value: Value.Attrs([]) },
])

# Every Value variant, nested, survives an S-expression round trip.
expect Sexpr.parse(Sexpr.to_str(sample)) == Ok(sample)

# Encoding tags each value and groups list items in one parenthesized list.
expect
	Sexpr.to_str(Value.List([Value.Int(1), Value.Str("a")]))
		== "(List ((Int 1) (Str \"a\")))"

# Attribute fields parse in any order and unknown fields are skipped.
expect {
	parsed : Try(Value, _)
	parsed = Sexpr.parse(
		"(Attrs (((extra 1) (value (Bool false)) (name \"k\"))))",
	)
	parsed == Ok(Value.Attrs([{ name: "k", value: Value.Bool(False) }]))
}

# Nesting beyond max_depth is rejected instead of recursing without bound.
expect {
	deep = Str.concat(Str.repeat("(List (", 100), Str.repeat("))", 100))
	parsed : Try(Value, _)
	parsed = Sexpr.parse(deep)
	parsed.is_err()
}

# Tags outside the Value union are rejected.
expect {
	parsed : Try(Value, _)
	parsed = Sexpr.parse("(Float 1)")
	parsed.is_err()
}
