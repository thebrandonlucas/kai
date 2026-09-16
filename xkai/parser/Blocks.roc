# Scan Kaifile blocks
Blocks := [].{
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
	Extracted := {
		blocks : List(Block),
		remaining : Str,
	}
	ByteRange := { end : U64, start : U64 }
	EmbeddedScan := {
		blocks : List(Block),
		ranges : List(ByteRange),
	}
	EmbeddedHeader : [FoundEmbeddedHeader({ name : Str, opening : U64 }), None]
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
	scan = |source| Blocks.scan_blocks(source.to_utf8(), 0, [])

	# Extract prefixed blocks from mixed body text and mask their complete byte
	# ranges so the remaining text keeps its original source offsets.
	extract : Str, Str -> Try(Extracted, Diagnostic)
	extract = |source, prefix| {
		bytes = source.to_utf8()
		scanned = Blocks.scan_embedded(
			bytes,
			prefix,
			0,
			0,
			[],
			[],
		)?
		masked = bytes.map_with_index(
			|byte, index|
				if byte == '\n' or !Blocks.in_ranges(index, scanned.ranges) {
					byte
				} else {
					' '
				},
		)
		Ok({
			blocks: scanned.blocks,
			remaining: Str.from_utf8(masked) ?? "",
		})
	}

	select_exact : List(Block), List(Str) -> Try(Selection, SelectionError)
	select_exact = |blocks, header| Blocks.select_next(blocks, header, Missing)

	select_next : List(Block),
	List(Str),
	Selection -> Try(
		Selection,
		SelectionError,
	)
	select_next = |blocks, header, found|
		match blocks {
			[] => Ok(found)
			[first, .. as rest] =>
				if first.header != header {
					Blocks.select_next(rest, header, found)
				} else {
					match found {
						Missing => Blocks.select_next(rest, header, Selected(first))
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
		index = Blocks.skip_trivia(bytes, raw_index)
		if index >= bytes.len() {
			Ok(blocks)
		} else {
			byte = Blocks.byte_at(bytes, index)
			if byte == '}' {
				Blocks.fail(ExtraClosingBrace, bytes, index)
			} else if byte == '{' {
				Blocks.fail(EmptyHeader, bytes, index)
			} else if !Blocks.is_name_byte(byte) {
				Blocks.fail(MalformedHeader, bytes, index)
			} else {
				parsed = Blocks.scan_header(bytes, index, [])?
				body_start = parsed.opening + 1
				body_end = Blocks.scan_body(bytes, body_start, 1)?
				block = {
					body: Blocks.slice(bytes, body_start, body_end),
					header: parsed.header,
					location: Blocks.location(bytes, body_start),
				}
				Blocks.scan_blocks(bytes, body_end + 1, blocks.append(block))
			}
		}
	}

	scan_embedded = |bytes, prefix, index, depth, blocks, ranges|
		if index >= bytes.len() {
			Ok({ blocks, ranges })
		} else {
			byte = Blocks.byte_at(bytes, index)
			if byte == '"' {
				rest = Blocks.scan_string(bytes, index + 1, index)?
				Blocks.scan_embedded(bytes, prefix, rest, depth, blocks, ranges)
			} else if byte == '#' {
				Blocks.scan_embedded(
					bytes,
					prefix,
					Blocks.skip_comment(bytes, index),
					depth,
					blocks,
					ranges,
				)
			} else if byte == '{' {
				Blocks.scan_embedded(
					bytes,
					prefix,
					index + 1,
					depth + 1,
					blocks,
					ranges,
				)
			} else if byte == '}' and depth > 0 {
				Blocks.scan_embedded(
					bytes,
					prefix,
					index + 1,
					depth - 1,
					blocks,
					ranges,
				)
			} else if depth == 0 and Blocks.is_name_byte(byte) {
				name_end = Blocks.find_name_end(bytes, index + 1)
				name = Blocks.slice(bytes, index, name_end)
				if name != prefix {
					Blocks.scan_embedded(
						bytes,
						prefix,
						name_end,
						depth,
						blocks,
						ranges,
					)
				} else {
					match Blocks.embedded_header(bytes, name_end) {
						None =>
							Blocks.scan_embedded(
								bytes,
								prefix,
								name_end,
								depth,
								blocks,
								ranges,
							)
						FoundEmbeddedHeader(header) => {
							body_start = header.opening + 1
							body_end = Blocks.scan_body(bytes, body_start, 1)?
							block = {
								body: Blocks.slice(bytes, body_start, body_end),
								header: [prefix, header.name],
								location: Blocks.location(bytes, body_start),
							}
							Blocks.scan_embedded(
								bytes,
								prefix,
								body_end + 1,
								depth,
								blocks.append(block),
								ranges.append({ start: index, end: body_end + 1 }),
							)
						}
					}
				}
			} else {
				Blocks.scan_embedded(
					bytes,
					prefix,
					index + 1,
					depth,
					blocks,
					ranges,
				)
			}
		}

	embedded_header : List(U8), U64 -> EmbeddedHeader
	embedded_header = |bytes, index| {
		name_start = Blocks.skip_trivia(bytes, index)
		if !Blocks.is_name_byte(Blocks.byte_at(bytes, name_start)) {
			None
		} else {
			name_end = Blocks.find_name_end(bytes, name_start + 1)
			opening = Blocks.skip_trivia(bytes, name_end)
			if Blocks.byte_at(bytes, opening) == '{' {
				FoundEmbeddedHeader({
					name: Blocks.slice(bytes, name_start, name_end),
					opening,
				})
			} else {
				None
			}
		}
	}

	in_ranges : U64, List(ByteRange) -> Bool
	in_ranges = |index, ranges|
		match ranges {
			[] => Bool.False
			[first, .. as rest] =>
				(index >= first.start and index < first.end) or
					Blocks.in_ranges(index, rest)
			}

	scan_header : List(U8),
	U64,
	List(Str) -> Try(
		{ header : List(Str), opening : U64 },
		Diagnostic,
	)
	scan_header = |bytes, raw_index, header| {
		index = Blocks.skip_trivia(bytes, raw_index)
		if index >= bytes.len() {
			Blocks.fail(MalformedHeader, bytes, index)
		} else {
			byte = Blocks.byte_at(bytes, index)
			if byte == '{' {
				Ok({ header, opening: index })
			} else if byte == '}' {
				Blocks.fail(ExtraClosingBrace, bytes, index)
			} else if !Blocks.is_name_byte(byte) {
				Blocks.fail(MalformedHeader, bytes, index)
			} else {
				rest = Blocks.find_name_end(bytes, index + 1)
				name = Blocks.slice(bytes, index, rest)
				Blocks.scan_header(bytes, rest, header.append(name))
			}
		}
	}

	scan_body : List(U8), U64, U64 -> Try(U64, Diagnostic)
	scan_body = |bytes, index, depth|
		if index >= bytes.len() {
			Blocks.fail(MissingClosingBrace, bytes, index)
		} else {
			byte = Blocks.byte_at(bytes, index)
			if byte == '"' {
				rest = Blocks.scan_string(bytes, index + 1, index)?
				Blocks.scan_body(bytes, rest, depth)
			} else if byte == '#' {
				Blocks.scan_body(bytes, Blocks.skip_comment(bytes, index), depth)
			} else if byte == '{' {
				Blocks.scan_body(bytes, index + 1, depth + 1)
			} else if byte == '}' and depth == 1 {
				Ok(index)
			} else if byte == '}' {
				Blocks.scan_body(bytes, index + 1, depth - 1)
			} else {
				Blocks.scan_body(bytes, index + 1, depth)
			}
		}

	scan_string : List(U8), U64, U64 -> Try(U64, Diagnostic)
	scan_string = |bytes, index, opening|
		if index >= bytes.len() {
			Blocks.fail(UnterminatedString, bytes, opening)
		} else {
			byte = Blocks.byte_at(bytes, index)
			if byte == '"' {
				Ok(index + 1)
			} else if byte == '\\' {
				if index + 1 >= bytes.len() {
					Blocks.fail(UnterminatedString, bytes, opening)
				} else {
					Blocks.scan_string(bytes, index + 2, opening)
				}
			} else {
				Blocks.scan_string(bytes, index + 1, opening)
			}
		}

	find_name_end : List(U8), U64 -> U64
	find_name_end = |bytes, index|
		if index < bytes.len() and Blocks.is_name_byte(Blocks.byte_at(bytes, index)) {
			Blocks.find_name_end(bytes, index + 1)
		} else {
			index
		}

	skip_trivia : List(U8), U64 -> U64
	skip_trivia = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Blocks.byte_at(bytes, index)
			if Blocks.is_whitespace(byte) {
				Blocks.skip_trivia(bytes, index + 1)
			} else if byte == '#' {
				Blocks.skip_trivia(bytes, Blocks.skip_comment(bytes, index))
			} else {
				index
			}
		}

	skip_comment : List(U8), U64 -> U64
	skip_comment = |bytes, index|
		if index >= bytes.len() or Blocks.byte_at(bytes, index) == '\n' {
			index
		} else {
			Blocks.skip_comment(bytes, index + 1)
		}

	location : List(U8), U64 -> Location
	location = |bytes, target| Blocks.find_location(bytes, target, 0, 1, 1)

	find_location : List(U8), U64, U64, U64, U64 -> Location
	find_location = |bytes, target, index, line, column|
		if index >= target {
			{ byte_offset: target, column, line }
		} else if Blocks.byte_at(bytes, index) == '\n' {
			Blocks.find_location(bytes, target, index + 1, line + 1, 1)
		} else {
			Blocks.find_location(bytes, target, index + 1, line, column + 1)
		}

	fail : DiagnosticKind, List(U8), U64 -> Try(a, Diagnostic)
	fail = |kind, bytes, index|
		Err({ kind, location: Blocks.location(bytes, index) })

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
		!Blocks.is_whitespace(byte) and
			byte != 0 and
				byte != '"' and
					byte != '#' and
						byte != '{' and
							byte != '}'
}
