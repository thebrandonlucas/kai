Config := [].{
	Location := {
		byte_offset : U64,
		column : U64,
		line : U64,
	}
	Block := {
		body : Str,
		header : List(Str),
		location : Location,
	}
	Selection : [Missing, Selected(Block)]
	SelectionError : [
		DuplicateHeader(
			{
				first : Location,
				header : List(Str),
				second : Location,
			},
		),
	]

	DiagnosticKind : [
		EmptyHeader,
		ExtraClosingBrace,
		MalformedHeader,
		MissingClosingBrace,
		UnterminatedString,
	]
	Diagnostic := { kind : DiagnosticKind, location : Location }

	scan : Str -> Try(List(Block), Diagnostic)
	scan = |source| Config.scan_blocks(source.to_utf8(), 0, [])

	select_exact : List(Block), List(Str) -> Try(Selection, SelectionError)
	select_exact = |blocks, header| Config.select_next(blocks, header, Missing)

	select_next : List(Block), List(Str), Selection -> Try(Selection, SelectionError)
	select_next = |blocks, header, found|
		match blocks {
			[] => Ok(found)
			[first, .. as rest] =>
				if first.header != header {
					Config.select_next(rest, header, found)
				} else {
					match found {
						Missing => Config.select_next(rest, header, Selected(first))
						Selected(previous) => Err(
							DuplicateHeader({
								first: previous.location,
								header,
								second: first.location,
							}),
						)
					}
				}
			}

	scan_blocks : List(U8), U64, List(Block) -> Try(List(Block), Diagnostic)
	scan_blocks = |bytes, raw_index, blocks| {
		index = Config.skip_trivia(bytes, raw_index)
		if index >= bytes.len() {
			Ok(blocks)
		} else {
			byte = Config.byte_at(bytes, index)
			if byte == '}' {
				Config.fail(ExtraClosingBrace, bytes, index)
			} else if byte == '{' {
				Config.fail(EmptyHeader, bytes, index)
			} else if !Config.is_name_byte(byte) {
				Config.fail(MalformedHeader, bytes, index)
			} else {
				parsed = Config.scan_header(bytes, index, [])?
				body_start = parsed.opening + 1
				body_end = Config.scan_body(bytes, body_start, 1)?
				block = {
					body: Config.slice(bytes, body_start, body_end),
					header: parsed.header,
					location: Config.location(bytes, body_start),
				}
				Config.scan_blocks(bytes, body_end + 1, blocks.append(block))
			}
		}
	}

	scan_header : List(U8),
	U64,
	List(Str) -> Try(
		{ header : List(Str), opening : U64 },
		Diagnostic,
	)
	scan_header = |bytes, raw_index, header| {
		index = Config.skip_trivia(bytes, raw_index)
		if index >= bytes.len() {
			Config.fail(MalformedHeader, bytes, index)
		} else {
			byte = Config.byte_at(bytes, index)
			if byte == '{' {
				Ok({ header, opening: index })
			} else if byte == '}' {
				Config.fail(ExtraClosingBrace, bytes, index)
			} else if !Config.is_name_byte(byte) {
				Config.fail(MalformedHeader, bytes, index)
			} else {
				rest = Config.find_name_end(bytes, index + 1)
				name = Config.slice(bytes, index, rest)
				Config.scan_header(bytes, rest, header.append(name))
			}
		}
	}

	scan_body : List(U8), U64, U64 -> Try(U64, Diagnostic)
	scan_body = |bytes, index, depth|
		if index >= bytes.len() {
			Config.fail(MissingClosingBrace, bytes, index)
		} else {
			byte = Config.byte_at(bytes, index)
			if byte == '"' {
				rest = Config.scan_string(bytes, index + 1, index)?
				Config.scan_body(bytes, rest, depth)
			} else if byte == '#' {
				Config.scan_body(bytes, Config.skip_comment(bytes, index), depth)
			} else if byte == '{' {
				Config.scan_body(bytes, index + 1, depth + 1)
			} else if byte == '}' and depth == 1 {
				Ok(index)
			} else if byte == '}' {
				Config.scan_body(bytes, index + 1, depth - 1)
			} else {
				Config.scan_body(bytes, index + 1, depth)
			}
		}

	scan_string : List(U8), U64, U64 -> Try(U64, Diagnostic)
	scan_string = |bytes, index, opening|
		if index >= bytes.len() {
			Config.fail(UnterminatedString, bytes, opening)
		} else {
			byte = Config.byte_at(bytes, index)
			if byte == '"' {
				Ok(index + 1)
			} else if byte == '\\' {
				if index + 1 >= bytes.len() {
					Config.fail(UnterminatedString, bytes, opening)
				} else {
					Config.scan_string(bytes, index + 2, opening)
				}
			} else {
				Config.scan_string(bytes, index + 1, opening)
			}
		}

	find_name_end : List(U8), U64 -> U64
	find_name_end = |bytes, index|
		if index < bytes.len() and Config.is_name_byte(Config.byte_at(bytes, index)) {
			Config.find_name_end(bytes, index + 1)
		} else {
			index
		}

	skip_trivia : List(U8), U64 -> U64
	skip_trivia = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Config.byte_at(bytes, index)
			if Config.is_whitespace(byte) {
				Config.skip_trivia(bytes, index + 1)
			} else if byte == '#' {
				Config.skip_trivia(bytes, Config.skip_comment(bytes, index))
			} else {
				index
			}
		}

	skip_comment : List(U8), U64 -> U64
	skip_comment = |bytes, index|
		if index >= bytes.len() or Config.byte_at(bytes, index) == '\n' {
			index
		} else {
			Config.skip_comment(bytes, index + 1)
		}

	location : List(U8), U64 -> Location
	location = |bytes, target| Config.find_location(bytes, target, 0, 1, 1)

	find_location : List(U8), U64, U64, U64, U64 -> Location
	find_location = |bytes, target, index, line, column|
		if index >= target {
			{ byte_offset: target, column, line }
		} else if Config.byte_at(bytes, index) == '\n' {
			Config.find_location(bytes, target, index + 1, line + 1, 1)
		} else {
			Config.find_location(bytes, target, index + 1, line, column + 1)
		}

	fail : DiagnosticKind, List(U8), U64 -> Try(a, Diagnostic)
	fail = |kind, bytes, index| Err({ kind, location: Config.location(bytes, index) })

	slice : List(U8), U64, U64 -> Str
	slice = |bytes, start, end| Str.from_utf8(
		bytes.sublist({ start, len: end - start }),
	) ?? ""

	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index| bytes.get(index) ?? 0

	is_whitespace : U8 -> Bool
	is_whitespace = |byte|
		byte == ' ' or
			byte == '\t' or
				byte == '\n' or
					byte == '\r'

	is_name_byte : U8 -> Bool
	is_name_byte = |byte|
		!Config.is_whitespace(byte) and
			byte != 0 and
				byte != '"' and
					byte != '#' and
						byte != '{' and
							byte != '}'
}
