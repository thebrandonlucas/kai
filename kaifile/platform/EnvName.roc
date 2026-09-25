# Checked environment and shell identities for authored configuration.
import ir.Project

## An environment or shell name, checked at compile time.
EnvName :: { name : Str }.{
	from_quote : Str -> Try(EnvName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if !Project.valid_name(raw) {
			Err(
				BadQuotedBytes(
					"\"${raw}\" is not an environment or shell name; "
						.concat("use letters, digits, - or _"),
				),
			)
		} else {
			Ok(EnvName.{ name: raw })
		}

	to_str : EnvName -> Str
	to_str = |value| value.name
}
