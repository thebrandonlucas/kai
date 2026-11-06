# Ported from roc-blueprint's blueprint-core/JsonData.roc: Copyright © 2026
# Luke Boswell and subsequent authors, under the Universal Permissive
# License (UPL), Version 1.0 (see LICENSE).
#
# Bounded JSON data codec for inert data; numbers retain their exact JSON
# lexemes.
# Duplicate keys, malformed Unicode and trailing input fail before planning.
import Lookup

JsonData := [
	Object(List({ name : Str, value : JsonData })),
	Array(List(JsonData)),
	String(Str),
	Number(Str),
	Boolean(Bool),
	Null,
].{
	Error : [InvalidJson(Str), LimitExceeded(Str)]

	is_eq : _

	## How much a document may hold, besides the 8 MiB and 128-level bounds
	## every document has, and what a key repeated in one object means:
	## `Reject` refuses it, and `CollapseIdentical` keeps one copy of a key
	## repeated with an equal value and refuses one repeated with another.
	Rules : { max_items : U64, duplicates : [Reject, CollapseIdentical] }

	## The rules `decode` and `encode` apply: small authority documents.
	defaults : Rules
	defaults = { max_items: 4096, duplicates: Reject }

	## Large documents such as SBOMs, whose arrays can hold every element of a
	## supply chain: the byte bound is what limits them.
	documents : Rules
	documents = { max_items: 131072, duplicates: Reject }

	decode : Str -> Try(JsonData, Error)
	decode = |text| JsonData.decode_with(text, defaults)

	decode_with : Str, Rules -> Try(JsonData, Error)
	decode_with = |text, rules| {
		if text.to_utf8().len() > 8388608 {
			return Err(LimitExceeded("JSON exceeds 8 MiB"))
		}
		parsed = parse(text.to_utf8(), 0, 0, rules)?
		if whitespace(text.to_utf8(), parsed.next) != text.to_utf8().len() {
			return Err(InvalidJson("trailing data in JSON"))
		}
		Ok(parsed.value)
	}

	encode : JsonData -> Try(Str, Error)
	encode = |value| JsonData.encode_with(value, defaults)

	encode_with : JsonData, Rules -> Try(Str, Error)
	encode_with = |value, rules| {
		_ = within(value, 0, rules)?
		text = encoded(value)
		if text.to_utf8().len() > 8388608 {
			return Err(LimitExceeded("JSON exceeds 8 MiB"))
		}
		parsed = JsonData.decode_with(text, { ..rules, duplicates: Reject })?
		if parsed != value {
			return Err(InvalidJson("invalid constructed JSON number or object"))
		}
		Ok(text)
	}

	## A JSON number lexeme with no fractional part, as JSON Schema counts an
	## integer: `3`, or `3.0`.
	whole : Str -> Bool
	whole = |lexeme| {
		digits = match lexeme.split_on(".") {
			[integral] => Ok(integral)
			[integral, fraction] if !fraction.is_empty() and
				fraction.to_utf8().all(|byte| byte == '0') => Ok(integral)
			_ => Err(Fractional)
		}
		match digits {
			Ok(integral) => !integral.is_empty() and
				integral.to_utf8().all(|byte| byte >= '0' and byte <= '9') and
					(integral == "0" or !integral.starts_with("0"))
			Err(_) => False
		}
	}

	## What went wrong, in words.
	message : Error -> Str
	message = |error|
		match error {
			InvalidJson(text) => text
			LimitExceeded(text) => text
		}

	## The member names of an object, in order; none for anything else.
	keys : JsonData -> List(Str)
	keys = |value|
		match value {
			Object(fields) => fields.map(|f| f.name)
			_ => []
		}

	quote : Str -> Str
	quote = |text| {
		var $bytes = ['"']
		for byte in text.to_utf8() {
			$bytes = $bytes.concat(
				match byte {
					'"' => ['\\', '"']
					'\\' => ['\\', '\\']
					_ => if byte < ' ' {
						digits = "0123456789abcdef".to_utf8()
						[
							'\\',
							'u',
							'0',
							'0',
							digits.get(byte.to_u64() // 16) ?? '0',
							digits.get(byte.to_u64() % 16) ?? '0',
						]
					} else [byte]
				},
			)
		}
		Str.from_utf8($bytes.append('"')) ?? "\"\""
	}

	field : JsonData, Str -> Try(JsonData, Error)
	field = |value, name| {
		fields = object(value)?
		fields.find_first(|f| f.name == name)
			.map_ok(|f| f.value).map_err(|_| InvalidJson("missing JSON field: ${name}"))
	}

	object : JsonData -> Try(List({ name : Str, value : JsonData }), Error)
	object = |value| match value {
		Object(fields) => Ok(fields)
		_ => Err(InvalidJson("expected JSON object"))
	}

	array : JsonData -> Try(List(JsonData), Error)
	array = |value| match value {
		Array(items) => Ok(items)
		_ => Err(InvalidJson("expected JSON array"))
	}

	string : JsonData -> Try(Str, Error)
	string = |value| match value {
		String(text) => Ok(text)
		_ => Err(InvalidJson("expected JSON string"))
	}

	set : JsonData, Str, JsonData -> Try(JsonData, Error)
	set = |value, name, replacement| {
		fields = object(value)?
		Ok(
			Object(
				fields.keep_if(|f| f.name != name)
					.append({ name, value: replacement }),
			),
		)
	}

	## The same value with the fields of every object in byte order of their
	## names, the order Nix writes a lock in.
	sorted : JsonData -> JsonData
	sorted = |value|
		match value {
			Object(fields) => Object(
				fields.map(|entry| { name: entry.name, value: sorted(entry.value) })
					.sort_with(|left, right| Lookup.bytewise(left.name, right.name)),
			)
			Array(items) => Array(items.map(sorted))
			_ => value
		}

}

# Private parser cursors and unchecked encoder are not public methods.

## Compute exact encoded length before allocating output; nested construction
## cannot bypass the same byte/depth/collection bounds as decoding.
within : JsonData, U64, JsonData.Rules -> Try(U64, JsonData.Error)
within = |value, depth, rules| {
	if depth > 128 {
		return Err(LimitExceeded("JSON exceeds 128 levels"))
	}
	var $size = 0
	match value {
		Object(fields) => {
			if fields.len() > rules.max_items {
				return Err(
					LimitExceeded("JSON object exceeds ${rules.max_items.to_str()} fields"),
				)
			}
			$size = 2
			var $names = []
			for field in fields {
				if $names.contains(field.name) {
					return Err(InvalidJson("duplicate JSON key: ${field.name}"))
				}
				if !$names.is_empty() {
					$size = $size + 1
				}
				$names = $names.append(field.name)
				$size = $size + quoted_size(field.name) + 1 + within(
					field.value,
					depth + 1,
					rules,
				)?
				if $size > 8388608 {
					return Err(LimitExceeded("JSON exceeds 8 MiB"))
				}
			}
		}
		Array(items) => {
			if items.len() > rules.max_items {
				return Err(
					LimitExceeded("JSON array exceeds ${rules.max_items.to_str()} items"),
				)
			}
			$size = 2 + (if (items.is_empty()) 0 else items.len() - 1)
			for item in items {
				$size = $size + within(item, depth + 1, rules)?
				if $size > 8388608 {
					return Err(LimitExceeded("JSON exceeds 8 MiB"))
				}
			}
		}
		String(text) => {
			$size = quoted_size(text)
		}
		Number(text) => {
			$size = text.to_utf8().len()
		}
		Boolean(boolean) => {
			$size = if (boolean) 4 else 5
		}
		Null => {
			$size = 4
		}
	}
	if $size > 8388608 {
		return Err(LimitExceeded("JSON exceeds 8 MiB"))
	}
	Ok($size)
}

quoted_size : Str -> U64
quoted_size = |text| {
	if text.to_utf8().len() > 8388606 {
		return 8388609
	}
	text.to_utf8().fold(
		2,
		|size, byte| size + (if (byte < ' ') 6 else if (byte == '"' or
			byte == '\\') 2 else 1),
	)
}

encoded : JsonData -> Str
encoded = |value| match value {
	Object(fields) => {
		items = fields.map(|f| "${JsonData.quote(f.name)}:${encoded(f.value)}")
		"{${Str.join_with(items, ",")}}"
	}
	Array(items) => "[${Str.join_with(items.map(encoded), ",")}]"
	String(text) => JsonData.quote(text)
	Number(text) => text
	Boolean(value_) => if (value_) "true" else "false"
	Null => "null"
}

Parsed : { value : JsonData, next : U64 }

parse : List(U8), U64, U64, JsonData.Rules -> Try(Parsed, JsonData.Error)
parse = |bytes, offset, depth, rules| {
	if depth > 128 {
		return Err(LimitExceeded("JSON exceeds 128 levels"))
	}
	i = whitespace(bytes, offset)
	match bytes.get(i) {
		Ok('"') => {
			parsed = read_string(bytes, i + 1)?
			Ok({ value: String(parsed.text), next: parsed.next })
		}
		Ok('{') => {
			var $fields = []
			var $next = whitespace(bytes, i + 1)
			if bytes.get($next) == Ok('}') {
				return Ok({ value: Object([]), next: $next + 1 })
			}
			while True {
				if $fields.len() >= rules.max_items {
					return Err(
						LimitExceeded("JSON object exceeds ${rules.max_items.to_str()} fields"),
					)
				}
				if bytes.get($next) != Ok('"') {
					return Err(InvalidJson("expected JSON object key"))
				}
				key = read_string(bytes, $next + 1)?
				colon = whitespace(bytes, key.next)
				if bytes.get(colon) != Ok(':') {
					return Err(InvalidJson("expected colon in JSON"))
				}
				item = parse(bytes, colon + 1, depth + 1, rules)?
				match ($fields.find_first(|f| f.name == key.text), rules.duplicates) {
					(Err(_), _) => {
						$fields = $fields.append({ name: key.text, value: item.value })
					}
					(Ok(earlier), CollapseIdentical) if earlier.value == item.value => {}
					_ => return Err(InvalidJson("duplicate JSON key: ${key.text}"))
				}
				$next = whitespace(bytes, item.next)
				if bytes.get($next) == Ok('}') {
					return Ok({ value: Object($fields), next: $next + 1 })
				}
				if bytes.get($next) != Ok(',') {
					return Err(InvalidJson("expected comma in JSON object"))
				}
				$next = whitespace(bytes, $next + 1)
			}
		}
		Ok('[') => {
			var $items = []
			var $next = whitespace(bytes, i + 1)
			if bytes.get($next) == Ok(']') {
				return Ok({ value: Array([]), next: $next + 1 })
			}
			while True {
				if $items.len() >= rules.max_items {
					return Err(
						LimitExceeded("JSON array exceeds ${rules.max_items.to_str()} items"),
					)
				}
				item = parse(bytes, $next, depth + 1, rules)?
				$items = $items.append(item.value)
				$next = whitespace(bytes, item.next)
				if bytes.get($next) == Ok(']') {
					return Ok({ value: Array($items), next: $next + 1 })
				}
				if bytes.get($next) != Ok(',') {
					return Err(InvalidJson("expected comma in JSON array"))
				}
				$next = whitespace(bytes, $next + 1)
			}
		}
		Ok('t') => literal(bytes, i, "true", Boolean(True))
		Ok('f') => literal(bytes, i, "false", Boolean(False))
		Ok('n') => literal(bytes, i, "null", Null)
		Ok(_) => number(bytes, i)
		Err(_) => Err(InvalidJson("unexpected end of JSON"))
	}
}

literal : List(U8), U64, Str, JsonData -> Try(Parsed, JsonData.Error)
literal = |bytes, i, text, value| {
	if bytes.drop_first(i).take_first(text.to_utf8().len()) == text.to_utf8() {
		Ok({ value, next: i + text.to_utf8().len() })
	} else Err(InvalidJson("invalid JSON literal"))
}

whitespace : List(U8), U64 -> U64
whitespace = |bytes, offset| {
	var $i = offset
	while match bytes.get($i) {
		Ok(byte) => [' ', '\n', '\r', '\t'].contains(byte)
		Err(_) => False
	} {
		$i = $i + 1
	}
	$i
}

digit : U8 -> Bool
digit = |byte| byte >= '0' and byte <= '9'

number : List(U8), U64 -> Try(Parsed, JsonData.Error)
number = |bytes, start| {
	var $i = start
	if bytes.get($i) == Ok('-') {
		$i = $i + 1
	}
	if bytes.get($i) == Ok('0') {
		$i = $i + 1
	} else {
		if !digit(bytes.get($i) ?? 0) {
			return Err(InvalidJson("invalid JSON number"))
		}
		while digit(bytes.get($i) ?? 0) {
			$i = $i + 1
		}
	}
	if bytes.get($i) == Ok('.') {
		$i = $i + 1
		if !digit(bytes.get($i) ?? 0) {
			return Err(InvalidJson("invalid JSON fraction"))
		}
		while digit(bytes.get($i) ?? 0) {
			$i = $i + 1
		}
	}
	if ['e', 'E'].contains(bytes.get($i) ?? 0) {
		$i = $i + 1
		if ['+', '-'].contains(bytes.get($i) ?? 0) {
			$i = $i + 1
		}
		if !digit(bytes.get($i) ?? 0) {
			return Err(InvalidJson("invalid JSON exponent"))
		}
		while digit(bytes.get($i) ?? 0) {
			$i = $i + 1
		}
	}
	text = Str.from_utf8(bytes.drop_first(start).take_first($i - start))
		.map_err(|_| InvalidJson("invalid UTF-8 number"))?
	Ok({ value: Number(text), next: $i })
}

read_string : List(U8), U64 -> Try({ text : Str, next : U64 }, JsonData.Error)
read_string = |bytes, offset| {
	var $i = offset
	var $out = []
	while $i < bytes.len() {
		byte = bytes.get($i) ?? 0
		$i = $i + 1
		if byte == '"' {
			text = Str.from_utf8($out)
				.map_err(|_| InvalidJson("invalid UTF-8 JSON string"))?
			return Ok({ text, next: $i })
		} else if byte == '\\' {
			escaped = bytes.get($i).map_err(|_| InvalidJson("unfinished JSON escape"))?
			$i = $i + 1
			match escaped {
				'"' => {
					$out = $out.append('"')
				}
				'\\' => {
					$out = $out.append('\\')
				}
				'/' => {
					$out = $out.append('/')
				}
				'b' => {
					$out = $out.append(8)
				}
				'f' => {
					$out = $out.append(12)
				}
				'n' => {
					$out = $out.append('\n')
				}
				'r' => {
					$out = $out.append('\r')
				}
				't' => {
					$out = $out.append('\t')
				}
				'u' => {
					var $point = hex4(bytes, $i)?
					$i = $i + 4
					if $point >= 0xD800 and $point <= 0xDBFF {
						if bytes.get($i) != Ok('\\') or bytes.get($i + 1) != Ok('u') {
							return Err(InvalidJson("unpaired JSON Unicode surrogate"))
						}
						low = hex4(bytes, $i + 2)?
						if low < 0xDC00 or low > 0xDFFF {
							return Err(InvalidJson("invalid JSON Unicode surrogate pair"))
						}
						$point = 0x10000 + ($point - 0xD800) * 1024 + low - 0xDC00
						$i = $i + 6
					} else if $point >= 0xDC00 and $point <= 0xDFFF {
						return Err(InvalidJson("unpaired JSON Unicode surrogate"))
					}
					$out = $out.concat(utf8($point))
				}
				_ => return Err(InvalidJson("invalid JSON string escape"))
			}
		} else if byte < ' ' {
			return Err(InvalidJson("unescaped control byte in JSON string"))
		} else {
			$out = $out.append(byte)
		}
	}
	Err(InvalidJson("unterminated JSON string"))
}

hex4 : List(U8), U64 -> Try(U32, JsonData.Error)
hex4 = |bytes, offset| {
	var $value = 0.U32
	var $i = offset
	while $i < offset + 4 {
		byte = bytes.get($i).map_err(|_| InvalidJson("short JSON Unicode escape"))?
		digit_ = if (byte >= '0' and byte <= '9') byte - '0'
		else if (byte >= 'a' and byte <= 'f') byte - 'a' + 10
		else if (byte >= 'A' and byte <= 'F') byte - 'A' + 10
		else return Err(InvalidJson("invalid JSON Unicode escape"))
		$value = $value * 16 + digit_.to_u32()
		$i = $i + 1
	}
	Ok($value)
}

utf8 : U32 -> List(U8)
utf8 = |point| {
	if point < 128 {
		[point.to_u8_wrap()]
	}
	else if point < 2048 {
		[(192 + point // 64).to_u8_wrap(), (128 + point % 64).to_u8_wrap()]
	} else if point < 65536 {
		[
			(224 + point // 4096).to_u8_wrap(),
			(128 + point // 64 % 64).to_u8_wrap(),
			(128 + point % 64).to_u8_wrap(),
		]
	} else {
		[
			(240 + point // 262144).to_u8_wrap(),
			(128 + point // 4096 % 64).to_u8_wrap(),
			(128 + point // 64 % 64).to_u8_wrap(),
			(128 + point % 64).to_u8_wrap(),
		]
	}
}

# Unicode surrogate pairs and escaped controls survive exact JSON round trips.
expect {
	text = "a\n\t\"\\é😀"
	JsonData.decode(JsonData.quote(text)) == Ok(JsonData.String(text))
		and JsonData.decode("\"\\ud83d\\ude00\"") == Ok(JsonData.String("😀"))
}

# A malformed authority never gets to a native provider process.
expect [
	"",
	"{}{}",
	"{\"a\":1,\"a\":2}",
	"[1,]",
	"01",
	"1e",
	"\"\\ud800\"",
	"\"\\udc00\"",
	"\"\\x00\"",
	"{\"a\" 1}",
	"true false",
]
	.all(|text| JsonData.decode(text).is_err())

# Native graph booleans, numbers, arrays and null remain typed data.
expect match JsonData.decode("{\"a\":[true,false,null,-1.25e+2,0]}") {
	Ok(value) => match JsonData.encode(value) {
		Ok(text) => JsonData.decode(text) == Ok(value)
		Err(_) => False
	}
	Err(_) => False
}

# Depth and collection bounds reject oversized untrusted lock structures.
expect {
	var $nested = "null"
	var $items = []
	var $i = 0
	while $i < 4097 {
		$items = $items.append(JsonData.Null)
		if $i < 130 {
			$nested = "[${$nested}]"
		}
		$i = $i + 1
	}
	JsonData.decode($nested).is_err()
		and JsonData.encode(JsonData.Array($items)).is_err()
}

# Decoding keeps member order and number lexemes, and sorted orders keys.
expect {
	result = || {
		value = JsonData.decode(
			"{\"b\":[{\"z\":1,\"a\":2}],\"a\":{\"d\":\"x\",\"c\""
				.concat(":true}}"),
		)?
		JsonData.encode(JsonData.sorted(value))
	}
	result() == Ok("{\"a\":{\"c\":true,\"d\":\"x\"},\"b\":[{\"a\":2,\"z\":1}]}")
}

# Constructed metadata is untrusted too: numeric lexemes cannot inject syntax.
expect [
	"",
	"null",
	"01",
	"1,2",
	"1e",
	"NaN",
	"1}\n{\"injected\":true",
].all(|text| JsonData.encode(JsonData.Number(text)).is_err())
# Encoding refuses a repeated key.
expect JsonData.encode(
	JsonData.Object([
		{ name: "a", value: JsonData.Null },
		{ name: "a", value: JsonData.Boolean(True) },
	]),
).is_err()
# A number keeps its exact lexeme.
expect JsonData.encode(
	JsonData.Number("340282366920938463463374607431768211455"),
) == Ok("340282366920938463463374607431768211455")
# An escaped key equal to another is a repeated key.
expect JsonData.decode("{\"a\":1,\"\\u0061\":2}").is_err()

# Nesting deeper than the bound is refused.
expect {
	var $nested = JsonData.Null
	var $depth = 0
	while $depth < 130 {
		$nested = JsonData.Array([$nested])
		$depth = $depth + 1
	}
	JsonData.encode($nested) == Err(LimitExceeded("JSON exceeds 128 levels"))
}

# A document larger than the bound is refused.
expect {
	var $text = "a"
	var $doublings = 0
	while $doublings < 23 {
		$text = $text.concat($text)
		$doublings = $doublings + 1
	}
	JsonData.decode($text.concat("a")) == Err(LimitExceeded("JSON exceeds 8 MiB"))
		and
		JsonData.encode(
			JsonData.String($text),
		) == Err(LimitExceeded("JSON exceeds 8 MiB"))
}

# Larger documents may hold more items; a key repeated with an equal value is
# one key only where the rules say so, and a conflicting one never is.
expect {
	items = Str.join_with(List.repeat("0", 5000), ",")
	JsonData.decode("[${items}]").is_err() and JsonData.decode_with(
		"[${items}]",
		JsonData.documents,
	).is_ok()
}
# A repeated key is refused by default.
expect JsonData.decode("{\"a\":[1],\"a\":[1]}").is_err()
# CollapseIdentical keeps one copy of a key repeated with an equal value.
expect JsonData.decode_with(
	"{\"a\":[1],\"b\":2,\"a\":[1]}",
	{ ..JsonData.documents, duplicates: CollapseIdentical },
) == Ok(
	JsonData.Object([
		{ name: "a", value: JsonData.Array([JsonData.Number("1")]) },
		{ name: "b", value: JsonData.Number("2") },
	]),
)
# CollapseIdentical refuses a key repeated with another value.
expect JsonData.decode_with(
	"{\"a\":1,\"a\":2}",
	{ ..JsonData.documents, duplicates: CollapseIdentical },
).is_err()
# keys lists member names, and message gives the error text.
expect JsonData.keys(JsonData.Object([{ name: "x", value: JsonData.Null }]))
	== ["x"] and

	JsonData.message(InvalidJson("bad")) == "bad"
# whole accepts integral lexemes only.
expect JsonData.whole("0") and
	JsonData.whole("12") and
		JsonData.whole("3.00") and
			!JsonData.whole("01") and
				!JsonData.whole("1.5") and
					!JsonData.whole("-1") and
						!JsonData.whole("1e3")
