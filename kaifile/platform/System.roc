## A Nix system such as "x86_64-linux" or "aarch64-linux", checked at
## compile time. Only its shape (`<arch>-<os>`, lowercase letters, digits
## and `_`) is checked, so less common systems work too.
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
			Err(
				BadQuotedBytes(
					"\"${raw}\" is not a system; expected <arch>-<os> "
						.concat("such as \"x86_64-linux\" or \"aarch64-linux\""),
				),
			)
		}
	}

	to_str : System -> Str
	to_str = |value| value.name
}
