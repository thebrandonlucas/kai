## A Nix system such as "x86_64-linux" or "aarch64-linux", checked at
## compile time. Only its shape (`<arch>-<os>`, lowercase letters, digits
## and `_`) is checked here; std rejects systems none of its backends support.
System :: { name : Str }.{
	from_quote : Str -> Try(System, [BadQuotedBytes(Str)])
	from_quote = |raw| {
		parts = raw.split_on("-")
		ok_part = |p|
			!p.is_empty() and p.to_utf8().all(
				|b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_',
			)
		if parts.len() == 2 and parts.all(ok_part) {
			Ok(System.{ name: raw })
		} else {
			Err(BadQuotedBytes(System.rejected(raw)))
		}
	}

	# Every value interpolated into one string has one type, so a URL such as
	# "${prefix}${system}" makes `prefix`'s string a System, and it lands here.
	# A system has no `/`, so such a string names the System to convert.
	rejected : Str -> Str
	rejected = |raw| {
		expected = "expected <arch>-<os> such as \"x86_64-linux\""
		if raw.contains("/") {
			"\"${raw}\" is not a system; ${expected}. A string interpolated "
				.concat("beside a System is read as one: interpolate ")
				.concat("`system.to_str()` rather than `system`")
		} else {
			"\"${raw}\" is not a system; ${expected} or \"aarch64-linux\""
		}
	}

	to_str : System -> Str
	to_str = |value| value.name
}

# A system's name of the wrong shape says what one looks like.
expect System.rejected("linux").ends_with("or \"aarch64-linux\"")

# A URL is one interpolated beside a System, and names the conversion.
expect System.rejected("https://example.com/tool-")
	.contains("`system.to_str()`")
