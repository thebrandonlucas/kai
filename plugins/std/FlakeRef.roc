## A flake reference such as "github:roc-lang/roc-overlay", checked at
## compile time.
FlakeRef :: { url : Str }.{
	from_quote : Str -> Try(FlakeRef, [BadQuotedBytes(Str)])
	from_quote = |raw| {
		schemes = [
			"github:",
			"gitlab:",
			"sourcehut:",
			"flake:",
			"git+",
			"path:",
			"file:",
			"https://",
			"http://",
			"tarball+",
		]
		match schemes.find_first(|s| raw.starts_with(s)) {
			Err(_) =>
				Err(
					BadQuotedBytes(
						"\"${raw}\" is not a flake reference; expected one "
							.concat("starting with ${Str.join_with(schemes, ", ")}"),
					),
				)
			Ok(scheme) =>
				if raw.contains(" ") or raw.drop_prefix(scheme).is_empty() {
					Err(
						BadQuotedBytes(
							"\"${raw}\" is not a flake reference; it is empty after "
								.concat("${scheme} or contains a space"),
						),
					)
				} else {
					Ok(FlakeRef.{ url: raw })
				}
			}
	}

	to_str : FlakeRef -> Str
	to_str = |value| value.url
}
