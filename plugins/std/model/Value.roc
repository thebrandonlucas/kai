# Generic tagged values the model carries for backend-specific data.
import api.Sexpr

## A generic, JSON-like value, used for backend-specific data in the model
## (`extensions` and `raw`). In S-expression form every value is tagged:
## `(Str "x")`, `(Int -3)`, `(Bool true)`, `(List (...))`,
## `(Attrs (((name "k") (value ...)) ...))`.
Value := [
	Str(Str),
	Int(I64),
	Bool(Bool),
	List(List(Value)),
	Attrs(List({ name : Str, value : Value })),
].{
	is_eq : _

	encoder_for : _
}

# Encoding tags each value and groups list items in one parenthesized list.
expect
	Sexpr.to_str(Value.List([Value.Int(1), Value.Str("a")]))
		== "(List ((Int 1) (Str \"a\")))"

# Attributes encode as name and value fields.
expect {
	text = Sexpr.to_str(Value.Attrs([{ name: "k", value: Value.Bool(False) }]))
	text.starts_with("(Attrs ")
		and text.contains("(name \"k\")")
			and text.contains("(value (Bool false))")
}
