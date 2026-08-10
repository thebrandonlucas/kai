# A generic representation of a `Kaifile` and associated parsing
# logic.
#
# This assumes no specific built-in keywords such that
# plugins may define their own, although the comments use the
# StdPlugin for examples.
#
# Example:
# ```kai
# on linux {
#     shell {
#         pkgs: ["cowsay"]
#     }
# }
# ```

# UTF-8 byte value translations into human-readable characters
# Config parser needs to do comparisons on these when reading
# the file.
import Bytes

# Top-level representation of the `Kaifile` config object.
# TODO: repo-wide rename `Kaifile`
Config := [].{
	# Keep track of where various things are.
	# Mainly used for diagnostics so we can tell the user where
	# errors are.
	Location := {
		# Zero-based index into the UTF-8 bytes of the exact source passed to
		# `scan`. Unlike line and column, this can address a byte directly without
		# rescanning the preceding text. A recursive scan therefore returns offsets
		# relative to the selected block body passed into that scan.
		byte_offset : U64,
		# One-based byte column and line for user-facing diagnostics.
		column : U64,
		line : U64,
	}
	# A section enclosed by curly braces.
	# e.g.
	#  ```Kaifile
	# # `header` is: `["on", "linux"]`
	# # `body` is the text between the outer braces: `shell { ... }`
	# # `location` is `{ byte_offset: 10, column: 11, line: 1 }`, the first
	# # byte after the opening `{` in the source passed to `scan`
	#   on linux {
	#     # This is a nested block with `header`: `shell`
	#     # and `body`: `pkgs: ["cowsay"]`
	#     shell {
	#       pkgs: ["cowsay"]
	#     }
	#   }
	#  ```
	Block := {
		body : Str,
		header : List(Str),
		location : Location,
	}
	# The result of exact-header lookup. Missing means no block had the requested
	# header; Selected contains the one matching block. More than one match is a
	# SelectionError rather than an arbitrary choice.
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

	# Syntax failures that can occur while locating generic blocks.
	DiagnosticKind : [
		EmptyHeader,
		ExtraClosingBrace,
		MalformedHeader,
		MissingClosingBrace,
		UnterminatedString,
	]
	# A scan failure paired with its byte-based source location.
	Diagnostic := { kind : DiagnosticKind, location : Location }

	# `scan` converts the raw string to a list of structurally valid `Block`s
	# which plugins may interpret. Scanning the complete example above returns
	# one block with header `["on", "linux"]`; scanning that block's body returns
	# the nested block with header `["shell"]`.
	scan : Str -> Try(List(Block), Diagnostic)
	scan = |source| Config.scan_blocks(source.to_utf8(), 0, [])

	# Return the unique block whose ordered header exactly matches. No match
	# returns Missing; duplicate matches return a SelectionError.
	select_exact : List(Block), List(Str) -> Try(Selection, SelectionError)
	select_exact = |blocks, header| Config.select_next(blocks, header, Missing)

	# recursively search for blocks which match the header.
	# if you find a matching header, 
	# check if the found `Selection` is missing.
	# If so, start recursing on the first and search through the list.
	# else, it's a duplicate header and we throw an error with the diagnostic
	# saying where it happened.
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

	# Find consecutive top-level blocks, starting after any whitespace or
	# comments and continuing immediately after each block's closing brace.
	scan_blocks : List(U8), U64, List(Block) -> Try(List(Block), Diagnostic)
	scan_blocks = |bytes, raw_index, blocks| {
		index = Config.skip_trivia(bytes, raw_index)
		# Trivia may extend through the end of an otherwise complete source.
		if index >= bytes.len() {
			Ok(blocks)
		} else {
			byte = Config.byte_at(bytes, index)
			# A top-level `}` has no matching block opened by this scan.
			if byte == Bytes.close_curly_brace {
				Config.fail(ExtraClosingBrace, bytes, index)
				# A block must have at least one ordered header word before `{`.
			} else if byte == Bytes.open_curly_brace {
				Config.fail(EmptyHeader, bytes, index)
				# Header words cannot begin with syntax or trivia bytes.
			} else if !Config.is_name_byte(byte) {
				Config.fail(MalformedHeader, bytes, index)
			} else {
				# Collect the complete header, then locate its matching closing brace.
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

	# Collect whitespace-separated header words in source order until `{`.
	# For `on linux {`, the result is `["on", "linux"]`.
	scan_header : List(U8),
	U64,
	List(Str) -> Try(
		{ header : List(Str), opening : U64 },
		Diagnostic,
	)
	scan_header = |bytes, raw_index, header| {
		index = Config.skip_trivia(bytes, raw_index)
		# Reaching the end before `{` leaves the header malformed.
		if index >= bytes.len() {
			Config.fail(MalformedHeader, bytes, index)
		} else {
			byte = Config.byte_at(bytes, index)
			# The opening brace completes the ordered-header-words contract.
			if byte == Bytes.open_curly_brace {
				Ok({ header, opening: index })
				# A closing brace cannot terminate a header.
			} else if byte == Bytes.close_curly_brace {
				Config.fail(ExtraClosingBrace, bytes, index)
				# Quotes, comments, and other syntax cannot form header words.
			} else if !Config.is_name_byte(byte) {
				Config.fail(MalformedHeader, bytes, index)
			} else {
				# Preserve this word, then continue toward `{`.
				rest = Config.find_name_end(bytes, index + 1)
				name = Config.slice(bytes, index, rest)
				Config.scan_header(bytes, rest, header.append(name))
			}
		}
	}

	# Locate the closing brace for a body. depth starts at one and tracks only
	# structural braces; braces inside strings and comments are protected.
	scan_body : List(U8), U64, U64 -> Try(U64, Diagnostic)
	scan_body = |bytes, index, depth|
	# Every body opened by the scanner must eventually close.
		if index >= bytes.len() {
			Config.fail(MissingClosingBrace, bytes, index)
		} else {
			byte = Config.byte_at(bytes, index)
			# Skip a complete quoted string so braces inside it do not change depth.
			if byte == Bytes.double_quote {
				rest = Config.scan_string(bytes, index + 1, index)?
				Config.scan_body(bytes, rest, depth)
				# Skip through a line comment so its braces are also ignored.
			} else if byte == Bytes.hash {
				Config.scan_body(bytes, Config.skip_comment(bytes, index), depth)
				# A nested block opens one additional structural level.
			} else if byte == Bytes.open_curly_brace {
				Config.scan_body(bytes, index + 1, depth + 1)
				# At the original depth, `}` ends the opaque body returned to the caller.
			} else if byte == Bytes.close_curly_brace and depth == 1 {
				Ok(index)
				# A nested `}` closes one level while scanning continues.
			} else if byte == Bytes.close_curly_brace {
				Config.scan_body(bytes, index + 1, depth - 1)
			} else {
				# All other body bytes are opaque to this structural scan.
				Config.scan_body(bytes, index + 1, depth)
			}
		}

	# Advance past a quoted string. Backslash protects the following byte,
	# including a quote or brace, without interpreting the escape's meaning.
	scan_string : List(U8), U64, U64 -> Try(U64, Diagnostic)
	scan_string = |bytes, index, opening|
	# Report the opening quote when its string never closes.
		if index >= bytes.len() {
			Config.fail(UnterminatedString, bytes, opening)
		} else {
			byte = Config.byte_at(bytes, index)
			# Return the byte immediately after the closing quote.
			if byte == Bytes.double_quote {
				Ok(index + 1)
				# Skip both the backslash and its protected byte.
			} else if byte == Bytes.backslash {
				if index + 1 >= bytes.len() {
					Config.fail(UnterminatedString, bytes, opening)
				} else {
					Config.scan_string(bytes, index + 2, opening)
				}
			} else {
				Config.scan_string(bytes, index + 1, opening)
			}
		}

	# -- Lexical helpers -----------------------------------------------------

	# Find the byte immediately after one header word.
	find_name_end : List(U8), U64 -> U64
	find_name_end = |bytes, index|
		if index < bytes.len() and Config.is_name_byte(Config.byte_at(bytes, index)) {
			Config.find_name_end(bytes, index + 1)
		} else {
			index
		}

	# Skip spacing and `#` line comments between blocks or header words.
	skip_trivia : List(U8), U64 -> U64
	skip_trivia = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Config.byte_at(bytes, index)
			if Config.is_whitespace(byte) {
				Config.skip_trivia(bytes, index + 1)
			} else if byte == Bytes.hash {
				Config.skip_trivia(bytes, Config.skip_comment(bytes, index))
			} else {
				index
			}
		}

	# Skip a comment through, but not past, its line feed. scan_body and
	# skip_trivia then handle that line feed in their own context.
	skip_comment : List(U8), U64 -> U64
	skip_comment = |bytes, index|
		if index >= bytes.len() or Config.byte_at(bytes, index) == Bytes.line_feed {
			index
		} else {
			Config.skip_comment(bytes, index + 1)
		}

	# -- Byte-based source locations ----------------------------------------

	# Convert a zero-based UTF-8 byte offset to its full source location.
	location : List(U8), U64 -> Location
	location = |bytes, target| Config.find_location(bytes, target, 0, 1, 1)

	# Count bytes from the source start; only line feed resets the one-based
	# byte column and advances the one-based line.
	find_location : List(U8), U64, U64, U64, U64 -> Location
	find_location = |bytes, target, index, line, column|
		if index >= target {
			{ byte_offset: target, column, line }
		} else if Config.byte_at(bytes, index) == Bytes.line_feed {
			Config.find_location(bytes, target, index + 1, line + 1, 1)
		} else {
			Config.find_location(bytes, target, index + 1, line, column + 1)
		}

	# Attach the offending byte's location to a syntax failure.
	fail : DiagnosticKind, List(U8), U64 -> Try(a, Diagnostic)
	fail = |kind, bytes, index| Err({ kind, location: Config.location(bytes, index) })

	# Decode the UTF-8 bytes in the half-open range [start, end).
	slice : List(U8), U64, U64 -> Str
	slice = |bytes, start, end| Str.from_utf8(
		bytes.sublist({ start, len: end - start }),
	) ?? ""

	# Safely inspect source at a byte offset, using NUL beyond the end.
	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index| bytes.get(index) ?? Bytes.nul

	# Recognize spacing allowed between header words and blocks.
	is_whitespace : U8 -> Bool
	is_whitespace = |byte|
		byte == Bytes.space or
			byte == Bytes.horizontal_tab or
				byte == Bytes.line_feed or
					byte == Bytes.carriage_return

	# A header word is any run of nontrivia bytes that excludes block, string,
	# comment, and sentinel syntax bytes. Meaning is left to the caller.
	is_name_byte : U8 -> Bool
	is_name_byte = |byte|
		!Config.is_whitespace(byte) and
			byte != Bytes.nul and
				byte != Bytes.double_quote and
					byte != Bytes.hash and
						byte != Bytes.open_curly_brace and
							byte != Bytes.close_curly_brace
}
