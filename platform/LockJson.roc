# Bounded JSON data codec for native Nix lock graphs and authority envelopes.
# Duplicate keys, malformed Unicode and trailing input fail before planning.
LockJson := [
	Object(List({ name : Str, value : LockJson })),
	Array(List(LockJson)),
	String(Str),
	Number(Str),
	Boolean(Bool),
	Null,
].{
	is_eq : _

	decode : Str -> Try(LockJson, Str)
	decode = |text| {
		if text.to_utf8().len() > 8388608 {
			return Err("lock JSON exceeds 8 MiB")
		}
		parsed = parse(text.to_utf8(), 0, 0)?
		if whitespace(text.to_utf8(), parsed.next) != text.to_utf8().len() {
			return Err("trailing data in lock JSON")
		}
		Ok(parsed.value)
	}

	encode : LockJson -> Str
	encode = |value| match value {
		Object(fields) => {
			items = fields.map(|f| "${quote(f.name)}:${encode(f.value)}")
			"{${Str.join_with(items, ",")}}"
		}
		Array(items) => "[${Str.join_with(items.map(encode), ",")}]"
		String(text) => quote(text)
		Number(text) => text
		Boolean(value_) => if value_ "true" else "false"
		Null => "null"
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

	field : LockJson, Str -> Try(LockJson, Str)
	field = |value, name| {
		fields = object(value)?
		fields.find_first(|f| f.name == name)
			.map_ok(|f| f.value).map_err(|_| "missing lock field: ${name}")
	}

	object : LockJson -> Try(List({ name : Str, value : LockJson }), Str)
	object = |value| match value {
		Object(fields) => Ok(fields)
		_ => Err("expected JSON object in lock")
	}

	array : LockJson -> Try(List(LockJson), Str)
	array = |value| match value {
		Array(items) => Ok(items)
		_ => Err("expected JSON array in lock")
	}

	string : LockJson -> Try(Str, Str)
	string = |value| match value {
		String(text) => Ok(text)
		_ => Err("expected JSON string in lock")
	}

	set : LockJson, Str, LockJson -> Try(LockJson, Str)
	set = |value, name, replacement| {
		fields = object(value)?
		Ok(
			Object(
				fields.keep_if(|f| f.name != name)
					.append({ name, value: replacement }),
			),
		)
	}

	Parsed : { value : LockJson, next : U64 }
	parse : List(U8), U64, U64 -> Try(Parsed, Str)
	parse = |bytes, offset, depth| {
		if depth > 128 {
			return Err("lock JSON exceeds 128 levels")
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
					if $fields.len() >= 4096 {
						return Err("lock JSON object exceeds 4096 fields")
					}
					if bytes.get($next) != Ok('"') {
						return Err("expected JSON object key")
					}
					key = read_string(bytes, $next + 1)?
					if $fields.any(|f| f.name == key.text) {
						return Err("duplicate lock JSON key: ${key.text}")
					}
					colon = whitespace(bytes, key.next)
					if bytes.get(colon) != Ok(':') {
						return Err("expected colon in lock JSON")
					}
					item = parse(bytes, colon + 1, depth + 1)?
					$fields = $fields.append({ name: key.text, value: item.value })
					$next = whitespace(bytes, item.next)
					if bytes.get($next) == Ok('}') {
						return Ok({ value: Object($fields), next: $next + 1 })
					}
					if bytes.get($next) != Ok(',') {
						return Err("expected comma in lock JSON object")
					}
					$next = whitespace(bytes, $next + 1)
				}
				Err("unterminated lock JSON object")
			}
			Ok('[') => {
				var $items = []
				var $next = whitespace(bytes, i + 1)
				if bytes.get($next) == Ok(']') {
					return Ok({ value: Array([]), next: $next + 1 })
				}
				while True {
					if $items.len() >= 4096 {
						return Err("lock JSON array exceeds 4096 items")
					}
					item = parse(bytes, $next, depth + 1)?
					$items = $items.append(item.value)
					$next = whitespace(bytes, item.next)
					if bytes.get($next) == Ok(']') {
						return Ok({ value: Array($items), next: $next + 1 })
					}
					if bytes.get($next) != Ok(',') {
						return Err("expected comma in lock JSON array")
					}
					$next = whitespace(bytes, $next + 1)
				}
				Err("unterminated lock JSON array")
			}
			Ok('t') => literal(bytes, i, "true", Boolean(True))
			Ok('f') => literal(bytes, i, "false", Boolean(False))
			Ok('n') => literal(bytes, i, "null", Null)
			Ok(_) => number(bytes, i)
			Err(_) => Err("unexpected end of lock JSON")
		}
	}

	literal : List(U8), U64, Str, LockJson -> Try(Parsed, Str)
	literal = |bytes, i, text, value| {
		if bytes.drop_first(i).take_first(text.to_utf8().len()) == text.to_utf8() {
			Ok({ value, next: i + text.to_utf8().len() })
		} else Err("invalid JSON literal")
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

	number : List(U8), U64 -> Try(Parsed, Str)
	number = |bytes, start| {
		var $i = start
		if bytes.get($i) == Ok('-') {
			$i = $i + 1
		}
		if bytes.get($i) == Ok('0') {
			$i = $i + 1
		} else {
			if !digit(bytes.get($i) ?? 0) {
				return Err("invalid JSON number")
			}
			while digit(bytes.get($i) ?? 0) {
				$i = $i + 1
			}
		}
		if bytes.get($i) == Ok('.') {
			$i = $i + 1
			if !digit(bytes.get($i) ?? 0) {
				return Err("invalid JSON fraction")
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
				return Err("invalid JSON exponent")
			}
			while digit(bytes.get($i) ?? 0) {
				$i = $i + 1
			}
		}
		text = Str.from_utf8(bytes.drop_first(start).take_first($i - start))
			.map_err(|_| "invalid UTF-8 number")?
		Ok({ value: Number(text), next: $i })
	}

	read_string : List(U8), U64 -> Try({ text : Str, next : U64 }, Str)
	read_string = |bytes, offset| {
		var $i = offset
		var $out = []
		while $i < bytes.len() {
			byte = bytes.get($i) ?? 0
			$i = $i + 1
			if byte == '"' {
				text = Str.from_utf8($out).map_err(|_| "invalid UTF-8 JSON string")?
				return Ok({ text, next: $i })
			} else if byte == '\\' {
				escaped = bytes.get($i).map_err(|_| "unfinished JSON escape")?
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
								return Err("unpaired JSON Unicode surrogate")
							}
							low = hex4(bytes, $i + 2)?
							if low < 0xDC00 or low > 0xDFFF {
								return Err("invalid JSON Unicode surrogate pair")
							}
							$point = 0x10000 + ($point - 0xD800) * 1024 + low - 0xDC00
							$i = $i + 6
						} else if $point >= 0xDC00 and $point <= 0xDFFF {
							return Err("unpaired JSON Unicode surrogate")
						}
						$out = $out.concat(utf8($point))
					}
					_ => return Err("invalid JSON string escape")
				}
			} else if byte < ' ' {
				return Err("unescaped control byte in JSON string")
			} else {
				$out = $out.append(byte)
			}
		}
		Err("unterminated JSON string")
	}

	hex4 : List(U8), U64 -> Try(U32, Str)
	hex4 = |bytes, offset| {
		var $value = 0.U32
		var $i = offset
		while $i < offset + 4 {
			byte = bytes.get($i).map_err(|_| "short JSON Unicode escape")?
			digit_ = if byte >= '0' and byte <= '9' byte - '0'
			else if byte >= 'a' and byte <= 'f' byte - 'a' + 10
			else if byte >= 'A' and byte <= 'F' byte - 'A' + 10
			else return Err("invalid JSON Unicode escape")
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
}

# Unicode surrogate pairs and escaped controls survive exact JSON round trips.
expect {
	text = "a\n\t\"\\é😀"
	LockJson.decode(LockJson.quote(text)) == Ok(LockJson.String(text))
		and LockJson.decode("\"\\ud83d\\ude00\"") == Ok(LockJson.String("😀"))
}

# A malformed authority never gets to a native backend process.
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
	.all(|text| LockJson.decode(text).is_err())

# Native graph booleans, numbers, arrays and null remain typed data.
expect match LockJson.decode("{\"a\":[true,false,null,-1.25e+2,0]}") {
	Ok(value) => LockJson.decode(LockJson.encode(value)) == Ok(value)
	Err(_) => False
}

# Depth and collection bounds reject oversized untrusted lock structures.
expect {
	var $nested = "null"
	var $items = []
	var $i = 0
	while $i < 4097 {
		$items = $items.append(LockJson.Null)
		if $i < 130 {
			$nested = "[${$nested}]"
		}
		$i = $i + 1
	}
	LockJson.decode($nested).is_err()
		and LockJson.decode(LockJson.encode(LockJson.Array($items))).is_err()
}
