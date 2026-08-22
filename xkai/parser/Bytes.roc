# A place to hold all UTF-8 byte values for characters the Body
# and Config parsers need to recognize. We do this because Roc
# can't yet do direct character comparisons.
#
# e.g. `if current_byte == '"'`
Bytes := [].{
	# `"` opens and closes string values.
	double_quote : U8
	double_quote = 34

	# `:` separates field names from values.
	colon : U8
	colon = 58

	# `{` opens a config block.
	open_curly_brace : U8
	open_curly_brace = 123

	# `}` closes a config block.
	close_curly_brace : U8
	close_curly_brace = 125

	# `[` opens a string-list value.
	open_square_bracket : U8
	open_square_bracket = 91

	# `]` closes a string-list value.
	close_square_bracket : U8
	close_square_bracket = 93

	# `,` separates string-list items.
	comma : U8
	comma = 44

	# `\` escapes the next string character.
	backslash : U8
	backslash = 92

	# `!` starts the printable ASCII range after space.
	exclamation_mark : U8
	exclamation_mark = 33

	# `$` opens Nix string interpolation.
	dollar_sign : U8
	dollar_sign = 36

	# `#` opens a body comment.
	hash : U8
	hash = 35

	# `-` is allowed in identifier references and artifact names.
	hyphen : U8
	hyphen = 45

	# `.` is allowed in identifier references and artifact names.
	period : U8
	period = 46

	# `~` ends the printable ASCII range.
	tilde : U8
	tilde = 126

	# ` ` is a space.
	space : U8
	space = 32

	# `\t` is a horizontal tab.
	horizontal_tab : U8
	horizontal_tab = 9

	# `\n` is a line feed.
	line_feed : U8
	line_feed = 10

	# `\r` is a carriage return.
	carriage_return : U8
	carriage_return = 13

	# `A` starts the uppercase field-name range.
	uppercase_a : U8
	uppercase_a = 65

	# `Z` ends the uppercase field-name range.
	uppercase_z : U8
	uppercase_z = 90

	# `a` starts the lowercase field-name range.
	lowercase_a : U8
	lowercase_a = 97

	# `z` ends the lowercase field-name range.
	lowercase_z : U8
	lowercase_z = 122

	# `_` is allowed at the start of a field name.
	underscore : U8
	underscore = 95

	# `0` starts the field-name digit range.
	digit_zero : U8
	digit_zero = 48

	# `9` ends the field-name digit range.
	digit_nine : U8
	digit_nine = 57

	# `\0` is the NUL sentinel for an out-of-range lookup.
	nul : U8
	nul = 0
}
