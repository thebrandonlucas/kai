# The one lock authority, .kai/lock.json. Version 2 holds one section per
# backend; version 1 was a lone Nix section, read as version 2's `nix`.
# Each backend reads and replaces only its own section.
import api.LockJson

LockFile := [].{

	## A backend's section, if the lock has one.
	section : Str, Str -> Try([Absent, Present(LockJson)], Str)
	section = |text, backend| {
		envelope = LockJson.decode(text)?
		match LockJson.field(envelope, "version")? {
			Number("1") =>
				if backend == "nix" {
					identity = LockJson.field(envelope, "identity")?
					graph = LockJson.field(envelope, "nix")?
					Ok(
						Present(
							Object([
								{ name: "identity", value: identity },
								{ name: "graph", value: graph },
							]),
						),
					)
				} else {
					Ok(Absent)
				}
			Number("2") =>
				match LockJson.field(envelope, backend) {
					Ok(found) => Ok(Present(found))
					Err(_) => Ok(Absent)
				}
			_ => Err("unsupported Kai lock version; run kai update")
		}
	}

	## The lock with `backend`'s section replaced and every other section
	## kept, as version 2; sections are ordered by backend.
	splice : [Absent, Present(Str)], Str, LockJson -> Try(Str, Str)
	splice = |previous, backend, contents| {
		kept = |other|
			match previous {
				Present(text) => LockFile.section(text, other)
				Absent => Ok(Absent)
			}
		var $sections = []
		for name in ["guix", "nix"] {
			found = if name == backend Present(contents) else kept(name)?
			match found {
				Present(value) => {
					$sections = $sections.append({ name, value })
				}
				Absent => {}
			}
		}
		sections = $sections
		Ok(
			LockJson.encode(
				Object([{ name: "version", value: Number("2") }].concat(sections)),
			)
				.concat("\n"),
		)
	}
}

section : LockJson
section = Object([{ name: "commit", value: String("abc") }])

# Version 1 is the Nix section; version 2 splices one backend and keeps the
# others unchanged.
expect {
	v1 = "{\"version\": 1, \"identity\": {}, \"nix\": {\"nodes\": {}}}"
	nix = LockFile.section(v1, "nix")
	spliced = LockFile.splice(Present(v1), "guix", section)
	kept = spliced.map_ok(|text| LockFile.section(text, "nix"))
	nix
		== Ok(
			Present(
				Object([
					{ name: "identity", value: Object([]) },
					{ name: "graph", value: Object([{ name: "nodes", value: Object([]) }]) },
				]),
			),
		)
		and LockFile.section(v1, "guix") == Ok(Absent)
			and kept == Ok(nix)
				and spliced.map_ok(|text| LockFile.section(text, "guix"))
					== Ok(Ok(Present(section)))
}
