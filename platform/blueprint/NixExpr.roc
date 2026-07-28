NixExpr := [
	Apply(NixExpr, NixExpr),
	AttrSet(List(Field)),
	Identifier(Str),
	Lambda(List(Str), NixExpr),
	ListExpr(List(NixExpr)),
	Select(NixExpr, List(Str)),
	String(Str),
].{
	Field := { name : Str, value : NixExpr }

	## Formats an expression deterministically without a trailing newline.
	format : NixExpr -> Str
	format = |expression| render_at(expression, 0)
}

render_at : NixExpr, U64 -> Str
render_at = |expression, depth|
	match expression {
		Identifier(name) => name
		String(value) => quote_string(value)
		ListExpr(items) => render_list(items, depth)
		AttrSet(fields) => render_attr_set(fields, depth)
		Lambda(arguments, body) => "{ ${Str.join_with(arguments, ", ")}, ... }:\n${indent(depth + 1)}${render_at(body, depth + 1)}"
		Select(base, path) => "${render_select_base(base, depth)}${render_path(path)}"
		Apply(function, argument) => "${render_apply_function(function, depth)} ${render_apply_argument(argument, depth)}"
	}

render_list : List(NixExpr), U64 -> Str
render_list = |items, depth|
	if items.is_empty() {
		"[]"
	} else {
		lines = items.map(|item| "${indent(depth + 1)}${render_at(item, depth + 1)}")
		"[\n${Str.join_with(lines, "\n")}\n${indent(depth)}]"
	}

render_attr_set : List(NixExpr.Field), U64 -> Str
render_attr_set = |fields, depth|
	if fields.is_empty() {
		"{}"
	} else {
		lines = fields.map(|{ name, value }| "${indent(depth + 1)}${quote_string(name)} = ${render_at(value, depth + 1)};")
		"{\n${Str.join_with(lines, "\n")}\n${indent(depth)}}"
	}

render_select_base : NixExpr, U64 -> Str
render_select_base = |base, depth|
	match base {
		Identifier(_) => render_at(base, depth)
		Select(_, _) => render_at(base, depth)
		_ => "(${render_at(base, depth)})"
	}

render_apply_function : NixExpr, U64 -> Str
render_apply_function = |function, depth|
	match function {
		Identifier(_) => render_at(function, depth)
		Select(_, _) => render_at(function, depth)
		_ => "(${render_at(function, depth)})"
	}

render_apply_argument : NixExpr, U64 -> Str
render_apply_argument = |argument, depth|
	match argument {
		Identifier(_) => render_at(argument, depth)
		String(_) => render_at(argument, depth)
		ListExpr(_) => render_at(argument, depth)
		AttrSet(_) => render_at(argument, depth)
		_ => "(${render_at(argument, depth)})"
	}

render_path : List(Str) -> Str
render_path = |path|
	Str.join_with(path.map(|segment| ".${quote_string(segment)}"), "")

quote_string : Str -> Str
quote_string = |value| {
	backslash = "\\"
	quote = "\""
	interpolation_open = Str.concat("$", "{")
	escaped_backslash = replace_all(value, backslash, "${backslash}${backslash}")
	escaped_quote = replace_all(escaped_backslash, quote, "${backslash}${quote}")
	escaped_interpolation = replace_all(escaped_quote, interpolation_open, "${backslash}${interpolation_open}")
	escaped_newline = replace_all(escaped_interpolation, "\n", "${backslash}n")
	escaped_return = replace_all(escaped_newline, "\r", "${backslash}r")
	escaped_tab = replace_all(escaped_return, "\t", "${backslash}t")
	"${quote}${escaped_tab}${quote}"
}

replace_all : Str, Str, Str -> Str
replace_all = |value, needle, replacement| Str.join_with(Str.split_on(value, needle), replacement)

indent : U64 -> Str
indent = |depth| Str.join_with(List.repeat("  ", depth), "")

## Strings escape Nix quotes and backslashes.
expect {
	backslash = "\\"
	quote = "\""
	expected = "${quote}quote: ${backslash}${quote} slash: ${backslash}${backslash}${quote}"
	NixExpr.format(NixExpr.String("quote: \" slash: \\")) == expected
}

## Nix interpolation openers are escaped as literal string data.
expect {
	interpolation_open = Str.concat("$", "{")
	expected = Str.concat(Str.concat("\"", "\\"), Str.concat(interpolation_open, "\""))
	NixExpr.format(NixExpr.String(interpolation_open)) == expected
}

## Lists retain item order and use stable indentation.
expect NixExpr.format(NixExpr.ListExpr([NixExpr.String("a"), NixExpr.String("b")])) == "[\n  \"a\"\n  \"b\"\n]"

## Attribute names are always safely quoted.
expect NixExpr.format(NixExpr.AttrSet([{ name: "not-an-identifier", value: NixExpr.String("value") }])) == "{\n  \"not-an-identifier\" = \"value\";\n}"

## Function application parenthesizes a lambda in function position.
expect NixExpr.format(NixExpr.Apply(NixExpr.Lambda(["x"], NixExpr.Identifier("x")), NixExpr.String("value"))) == "({ x, ... }:\n  x) \"value\""
