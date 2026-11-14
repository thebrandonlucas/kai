# `kai lock`: every input .kai/lock.json pins, as the documented JSON of
# docs/lock.md, for tools such as SBOM generators. Read-only: it reads the
# lock text kai passes, and needs no backend or network. `kai update` notes
# what it changed by the same entries.
import pf.Implementation
import pf.Layout
import pf.LockFile
import pf.LockJson
import pf.Plan
import nix.Locks
import direct.DirectBackend

LockReport := [].{

	## Bumped only when a field changes meaning or goes away; new fields keep it.
	schema_version : U64
	schema_version = 1

	## A plan printing the report, or why the lock cannot give one.
	plan : Implementation.Context -> Try(Plan, Plan.Failure)
	plan = |{ lock, layout, .. }| {
		path = layout.lock_path
		failure = |code, message|
			{ code, message, hint: "kai update", suggestions: [] }
		text = match lock {
			Present(found) => found
			Absent => return Err(failure("missing_lock", "no lock file at ${path}"))
		}
		report = LockReport.json(text).map_err(
			|why| failure("invalid_lock", "cannot read the lock file ${path}: ${why}"),
		)?
		Ok(Plan.{ steps: [Print(report)], next: Done })
	}

	## The report of a lock file's text: its Nix and direct pins. Sections
	## other plugins own, such as the guix plugin's, are theirs to report.
	json : Str -> Try(Str, Str)
	json = |text| {
		inputs = nix(text)?.concat(direct(text)?)
		Ok(
			LockJson.encode(
				object([
					("schema_version", Number(LockReport.schema_version.to_str())),
					("inputs", Array(inputs.map(entry))),
				]),
			),
		)
	}

	## What an update changed in the lock's Nix or direct section, from the
	## lock it started from to the text it publishes: one line per entry, by
	## the name `kai lock` gives it.
	changes : [Nix, Direct], [Absent, Present(Str)], Str -> List(Str)
	changes = |section, previous, current| {
		read = |lock_text| {
			found = match section {
				Nix => nix(lock_text)
				Direct => direct(lock_text)
			}
			(found ?? []).map(|e| { name: e.name, pin: pin(e) })
		}
		before = match previous {
			Present(text) => read(text)
			Absent => []
		}
		LockReport.lines(before, read(current))
	}

	## One line per entry added, moved or removed between two lists of pins,
	## each shortened to 8 characters: `default 1d060086 → 7dcdd873`,
	## `tools added at 4975466d`, `tools/nixpkgs removed`; or `no input
	## changed`.
	lines : List(Pinned), List(Pinned) -> List(Str)
	lines = |before, after| {
		short = |full| Str.from_utf8_lossy(full.to_utf8().take_first(8))
		pin_in = |list, name|
			list.find_first(|p| p.name == name).map_ok(|p| short(p.pin))
		var $lines = []
		for named in after.concat(before) {
			line = match (pin_in(before, named.name), pin_in(after, named.name)) {
				(Ok(old), Ok(new)) if old != new => "${named.name} ${old} → ${new}"
				(Err(_), Ok(new)) => "${named.name} added at ${new}"
				(Ok(_), Err(_)) => "${named.name} removed"
				_ => ""
			}
			if line != "" and !$lines.contains(line) {
				$lines = $lines.append(line)
			}
		}
		if ($lines.is_empty()) ["no input changed"] else $lines
	}

	## A lock entry's name and its pin: a commit, or else a content hash.
	Pinned : { name : Str, pin : Str }
}

## An entry's locked revision, else its hash without an SRI prefix.
pin : Entry -> Str
pin = |e| {
	full = match (e.revision, e.hash) {
		(String(revision), _) => revision
		(_, found) => LockJson.string(LockJson.field(found, "value") ?? Null) ?? ""
	}
	full.drop_prefix("sha256-")
}

Entry : {
	section : Str,
	kind : Str,
	name : Str,
	url : Str,
	revision : LockJson,
	hash : LockJson,
	size : LockJson,
	system : LockJson,
	locked : LockJson,
}

blank : Str, Str, Str, Str -> Entry
blank = |section, kind, name, url| {
	section,
	kind,
	name,
	url,
	revision: Null,
	hash: Null,
	size: Null,
	system: Null,
	locked: Null,
}

entry : Entry -> LockJson
entry = |e|
	object([
		("section", text(e.section)),
		("kind", text(e.kind)),
		("name", text(e.name)),
		("url", text(e.url)),
		("revision", e.revision),
		("hash", e.hash),
		("size", e.size),
		("system", e.system),
		("locked", e.locked),
	])

## A SHA-256 as the section records it: of a NAR serialization or of a file's
## bytes, in SRI, Nix base32 or hex.
sha256 : Str, Str, Str -> LockJson
sha256 = |of, encoding, value|
	object([
		("algorithm", text("sha256")),
		("of", text(of)),
		("encoding", text(encoding)),
		("value", text(value)),
	])

## Each root input in declaration order, then the inputs they pull in, each
## once, named by the path to it from a root input.
nix : Str -> Try(List(Entry), Str)
nix = |lock_text| {
	section = match LockFile.section(lock_text, "nix")? {
		Present(found) => found
		Absent => return Ok([])
	}
	# The section is checked as plans check it before anything reads it.
	_ = Locks.decode(lock_text)?
	declared = LockJson.object(
		LockJson.field(LockJson.field(section, "identity")?, "inputs")?,
	)?
	graph = LockJson.field(section, "graph")?
	nodes = LockJson.field(graph, "nodes")?
	root = LockJson.string(LockJson.field(graph, "root")?)?
	roots = LockJson.field(LockJson.field(nodes, root)?, "inputs") ?? Object([])
	var $entries = []
	var $seen = [root]
	var $queue = []
	for input in declared {
		id = LockJson.string(LockJson.field(roots, input.name)?)?
		node = LockJson.field(nodes, id)?
		kind = match LockJson.string(LockJson.field(input.value, "kind")?)? {
			"auto" => "package_source"
			"packages" => "package_source"
			"flake" => "flake_input"
			other => other
		}
		url = LockJson.string(LockJson.field(input.value, "ref")?)?
		$entries = $entries.append(pinned(kind, input.name, url, node)?)
		$seen = $seen.append(id)
		$queue = $queue.concat(edges(input.name, node))
	}
	var $index = 0
	while $index < $queue.len() {
		(path, id) = match $queue.get($index) {
			Ok(edge) => edge
			Err(_) => ("", "")
		}
		$index = $index + 1
		if !$seen.contains(id) {
			node = LockJson.field(nodes, id)?
			url = flake_ref(LockJson.field(node, "original")?)
			$entries = $entries.append(pinned("transitive", path, url, node)?)
			$seen = $seen.append(id)
			$queue = $queue.concat(edges(path, node))
		}
	}
	Ok($entries)
}

## A Nix node's entry: its locked revision, if any, and NAR hash.
pinned : Str, Str, Str, LockJson -> Try(Entry, Str)
pinned = |kind, name, url, node| {
	locked = LockJson.field(node, "locked")?
	nar = LockJson.string(LockJson.field(locked, "narHash")?)?
	revision = match LockJson.field(locked, "rev") {
		Ok(String(rev)) => String(rev)
		_ => Null
	}
	Ok({
		..blank("nix", kind, name, url),
		revision,
		hash: sha256("nar", "sri", nar),
		locked,
	})
}

## The inputs a node names directly, by their path; follows name a node
## reached another way.
edges : Str, LockJson -> List((Str, Str))
edges = |path, node| {
	inputs = LockJson.object(LockJson.field(node, "inputs") ?? Object([])) ?? []
	inputs.keep_oks(
		|input|
			match input.value {
				String(id) => Ok(("${path}/${input.name}", id))
				_ => Err({})
			},
	)
}

## The flake reference Nix's `original` attributes spell.
flake_ref : LockJson -> Str
flake_ref = |attrs| {
	at = |name| LockJson.string(LockJson.field(attrs, name) ?? Null) ?? ""
	kind = at("type")
	ref = at("ref")
	suffix = if (ref.is_empty()) "" else "/${ref}"
	if ["github", "gitlab", "sourcehut"].contains(kind) {
		"${kind}:${at("owner")}/${at("repo")}${suffix}"
	} else if kind == "indirect" {
		"${at("id")}${suffix}"
	} else if kind == "path" {
		"path:${at("path")}"
	} else if kind == "git" and !ref.is_empty() {
		"git+${at("url")}?ref=${ref}"
	} else {
		"${kind}+${at("url")}"
	}
}

## Each downloaded file by its key: `<fetch>/<system>`, or `<fetch>` for one
## file several systems share.
direct : Str -> Try(List(Entry), Str)
direct = |lock_text| {
	section = match LockFile.section(lock_text, "direct")? {
		Present(found) => found
		Absent => return Ok([])
	}
	pins = DirectBackend.read(section)?
	Ok(
		pins.map(
			|p| {
				system = match p.key.split_on("/") {
					[_, named] => String(named)
					_ => Null
				}
				{
					..blank("direct", "file", p.key, p.url),
					hash: sha256("file", "hex", p.sha256),
					size: Number(p.size.to_str()),
					system,
				}
			},
		),
	)
}

object : List((Str, LockJson)) -> LockJson
object = |fields| Object(fields.map(|(name, value)| { name, value }))

text : Str -> LockJson
text = |value| String(value)

# The value at `path` in the report of `lock_text`: object field names, or
# array indexes as digits.
report_at : Str, List(Str) -> Try(LockJson, Str)
report_at = |lock_text, path| {
	var $value = LockJson.decode(LockReport.json(lock_text)?)?
	for segment in path {
		$value = match U64.from_str(segment) {
			Ok(index) =>
				LockJson.array($value)?.get(index).map_err(|_| "no ${segment}")?
			Err(_) => LockJson.field($value, segment)?
		}
	}
	Ok($value)
}

nar = "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU="

rev = "4975466d324710c576dc11ad614684e6bd8cad8e"

commit = "0123456789abcdef0123456789abcdef01234567"

hex = "ab".repeat(32)

github = |repo, extra|
	"{\"owner\":\"NixOS\",\"repo\":\"${repo}\",\"type\":\"github\"${extra}}"

locked_github = |repo|
	github(repo, ",\"rev\":\"${rev}\",\"narHash\":\"${nar}\",\"lastModified\":1")

nix_section =
	"{\"identity\":{\"inputs\":{\"tools\":{\"ref\":\"github:NixOS/tools\","
		.concat("\"kind\":\"overlay\",\"flake\":true},")
		.concat("\"default\":{\"ref\":\"github:NixOS/nixpkgs/nixos-unstable\",")
		.concat("\"kind\":\"auto\",\"flake\":true}},\"overlays\":{}},")
		.concat("\"graph\":{\"version\":7,\"root\":\"root\",\"nodes\":{")
		.concat("\"root\":{\"inputs\":{\"default\":\"default\",")
		.concat("\"tools\":\"tools\"}},")
		.concat("\"default\":{\"locked\":${locked_github("nixpkgs")},")
		.concat("\"original\":${github("nixpkgs", ",\"ref\":\"nixos-unstable\"")}},")
		.concat("\"tools\":{\"inputs\":{\"utils\":\"utils\",")
		.concat("\"nixpkgs\":[\"default\"]},")
		.concat("\"locked\":${locked_github("tools")},")
		.concat("\"original\":${github("tools", "")}},")
		.concat("\"utils\":{\"locked\":${locked_github("utils")},")
		.concat("\"original\":${github("utils", "")}}}}}")

guix_section =
	"{\"identity\":{\"channels\":[\"guix\"]},\"channels\":[{\"name\":\"guix\","
		.concat("\"url\":\"https://git.guix.gnu.org/guix.git\",")
		.concat("\"branch\":\"master\",")
		.concat("\"commit\":\"${commit}\",\"introduction\":{}}],")
		.concat("\"sources\":[{\"name\":\"assets\",\"path\":\"assets\",")
		.concat("\"hash\":\"0abc\"}]}")

direct_section =
	"{\"files\":[{\"key\":\"tool/x86_64-linux\",\"sha256\":\"${hex}\","
		.concat("\"size\":42,\"url\":\"https://example.com/tool\"},")
		.concat("{\"key\":\"data\",\"sha256\":\"${hex}\",")
		.concat("\"size\":7,\"url\":\"https://example.com/data\"}]}")

lock_text =
	"{\"version\":2,\"direct\":${direct_section},\"guix\":${guix_section},"
		.concat("\"nix\":${nix_section}}")

# Root inputs keep their declaration order and the names `kai spec` gives
# them; what they pull in follows, named by its path, and follows are not
# repeated. Nix nodes pin a NAR hash, direct files a file hash, size and
# system, null for one file several systems share; another plugin's section,
# such as guix, is left out.
expect {
	at = |index, field| ["inputs", index, field]
	[
		(["schema_version"], Number("1")),
		(at("0", "name"), String("tools")),
		(at("0", "kind"), String("overlay")),
		(at("0", "url"), String("github:NixOS/tools")),
		(at("1", "name"), String("default")),
		(at("1", "kind"), String("package_source")),
		(at("1", "revision"), String(rev)),
		(at("1", "hash").concat(["value"]), String(nar)),
		(at("1", "hash").concat(["of"]), String("nar")),
		(at("1", "locked").concat(["owner"]), String("NixOS")),
		(at("2", "name"), String("tools/utils")),
		(at("2", "kind"), String("transitive")),
		(at("2", "url"), String("github:NixOS/utils")),
		(at("3", "section"), String("direct")),
		(at("3", "name"), String("tool/x86_64-linux")),
		(at("3", "system"), String("x86_64-linux")),
		(at("3", "size"), Number("42")),
		(at("3", "hash").concat(["encoding"]), String("hex")),
		(at("3", "locked"), Null),
		(at("4", "name"), String("data")),
		(at("4", "system"), Null),
	].all(|(path, expected)| report_at(lock_text, path) == Ok(expected))
		and report_at(lock_text, ["inputs", "5"]).is_err()
}

# A lock with no sections reports no inputs; a missing lock is missing_lock,
# and a malformed one invalid_lock.
expect {
	context = |lock| {
		args: [],
		backend: "",
		host: { system: "x86_64-linux" },
		layout: Layout.{
			project_root: "/p",
			workspace: "/p/.kai",
			generated_root: "/p/.kai/generated",
			lock_path: "/p/.kai/lock.json",
		},
		revision: { describe: "", commit_date: "" },
		lock,
		phase: 0,
		observed: [],
	}
	code = |lock|
		match LockReport.plan(context(lock)) {
			Ok(_) => ""
			Err(failure) => failure.code
		}
	empty = "{\"schema_version\":1,\"inputs\":[]}"
	LockReport.json("{\"version\":2}") == Ok(empty)
		and code(Absent) == "missing_lock"
		and code(Present("{\"version\":2,\"direct\":{}}")) == "invalid_lock"
		and code(Present(lock_text)) == ""
}

# Making `tools/utils` follow `default` drops its node, and an update says
# so; a direct file no longer declared is removed too, and the first pins
# are added at their hashes.
expect {
	followed = lock_text.replace_first(
		"{\"utils\":\"utils\",",
		"{\"utils\":[\"default\"],",
	)
	data = ",{\"key\":\"data\",\"sha256\":\"${hex}\","
		.concat("\"size\":7,\"url\":\"https://example.com/data\"}")
	dropped = lock_text.replace_first(data, "")
	LockReport.changes(Nix, Present(lock_text), followed)
		== ["tools/utils removed"]
		and LockReport.changes(Nix, Present(lock_text), lock_text)
			== ["no input changed"]
		and LockReport.changes(Direct, Present(lock_text), dropped)
			== ["data removed"]
		and LockReport.changes(Direct, Absent, lock_text)
			== ["tool/x86_64-linux added at abababab", "data added at abababab"]
}

# Pins are compared and shown by their first 8 characters, each change once.
expect {
	before = [{ name: "a", pin: "1d060086ff" }, { name: "b", pin: "00" }]
	after = [{ name: "a", pin: "7dcdd873ee" }, { name: "c", pin: "11" }]
	LockReport.lines(before, after)
		== ["a 1d060086 → 7dcdd873", "c added at 11", "b removed"]
		and LockReport.lines(before, before) == ["no input changed"]
}
