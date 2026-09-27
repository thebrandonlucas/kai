# Checked package source and flake input identities for authored configuration.
import ir.Project

## A package source or flake input name, checked at compile time.
InputName :: { name : Str }.{
	from_quote : Str -> Try(InputName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if !Project.valid_name(raw) {
			Err(
				BadQuotedBytes(
					"\"${raw}\" is not an input name; "
						.concat("use letters, digits, - or _"),
				),
			)
		} else {
			Ok(InputName.{ name: raw })
		}

	to_str : InputName -> Str
	to_str = |value| value.name
}
