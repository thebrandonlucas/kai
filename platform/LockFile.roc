# The one lock authority, .kai/lock.json. Version 2 holds one section per
# backend; version 1 was a lone Nix section, read as version 2's `nix`.
# Each backend reads and replaces only its own section.
import LockJson

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
		for name in ["direct", "guix", "nix"] {
			found = if (name == backend) Present(contents) else kept(name)?
			match found {
				Present(value) => {
					$sections = $sections.append({ name, value })
				}
				Absent => {}
			}
		}
		sections = $sections
		version = { name: "version", value: Number("2") }
		Ok(LockFile.layout(Object([version].concat(sections)), 0).concat("\n"))
	}

	## The lock's text, laid out so that `git diff` shows one changed entry,
	## such as a downloaded file, a Nix input or a Guix channel, as one
	## changed line. Objects open one member per line for the first four
	## levels, down to each section's entries, and arrays one item per line;
	## everything deeper, and each array's item, is compact JSON.
	layout : LockJson, U64 -> Str
	layout = |value, depth| {
		indent = "  ".repeat(depth + 1)
		close = "  ".repeat(depth)
		lines = |opening, members, closing|
			"${opening}\n${Str.join_with(members, ",\n")}\n${close}${closing}"
		match value {
			Object(fields) if depth < 4 and !fields.is_empty() =>
				lines(
					"{",
					fields.map(
						|f|
							"${indent}${LockJson.quote(f.name)}: "
								.concat(LockFile.layout(f.value, depth + 1)),
					),
					"}",
				)
			Array(items) if depth < 4 and !items.is_empty() =>
				lines("[", items.map(|item| "${indent}${LockJson.encode(item)}"), "]")
			_ => LockJson.encode(value)
		}
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

# Each section's entries are one line each, so changing one download changes
# one line; the old one-line lock reads the same and is rewritten unchanged
# in value.
expect {
	file = |key, size|
		Object([
			{ name: "key", value: String(key) },
			{ name: "size", value: Number(size) },
		])
	direct = |size|
		Object([{ name: "files", value: Array([file("a", "1"), file("b", size)]) }])
	input = Object([{ name: "flake", value: Boolean(True) }])
	default = Object([{ name: "default", value: input }])
	inputs = Object([{ name: "inputs", value: default }])
	nix = Object([{ name: "identity", value: inputs }])
	one_line = "{\"version\":2,\"direct\":${LockJson.encode(direct("2"))},"
		.concat("\"nix\":${LockJson.encode(nix)}}\n")
	match LockFile.splice(Present(one_line), "direct", direct("2")) {
		Ok(written) => {
			moved = LockFile.splice(Present(written), "direct", direct("3")) ?? ""
			before = written.split_on("\n")
			changed = moved.split_on("\n").keep_if(|line| !before.contains(line))
			written
				== (
					\\{
					\\  "version": 2,
					\\  "direct": {
					\\    "files": [
					\\      {"key":"a","size":1},
					\\      {"key":"b","size":2}
					\\    ]
					\\  },
					\\  "nix": {
					\\    "identity": {
					\\      "inputs": {
					\\        "default": {"flake":true}
					\\      }
					\\    }
					\\  }
					\\}
					\\
				)
				and LockJson.decode(written) == LockJson.decode(one_line)
				and LockFile.splice(Present(written), "direct", direct("2"))
					== Ok(written)
				and changed == ["      {\"key\":\"b\",\"size\":3}"]
		}
		Err(_) => False
	}
}
