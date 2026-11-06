# The evidence manifest written beside the sidecars of one subject.
#
# Ported from roc-blueprint's blueprint-core/Manifest.roc: Copyright © 2026
# Luke Boswell and subsequent authors, under the Universal Permissive
# License (UPL), Version 1.0 (see LICENSE).
import JsonData
import Lookup
import Profile
import Sidecar

## The evidence manifest `bind` writes beside the sidecars of one subject:
## which files it wrote, from which inventory, with the digest and size of
## each, so a publisher that rehashes every asset before signing can tie each
## sidecar to its subject and to the inventory it was bound from without
## reconstructing that mapping by hand. It is evidence about files, not a
## fourth rendering of the SBOM: it names files by name only, never by path,
## and holds no credential. `render` writes one deterministically, `read`
## takes it back, and `check` holds it to what a checker measured.
Manifest := [].{

	## One sidecar the manifest lists, by its name beside the manifest.
	Entry : { filename : Str, format : Str, sha256 : Str, size : U64 }

	Subject : {
		filename : Str,
		version : Str,
		target : Str,
		sha256 : Str,
		size : U64,
	}

	Context : { namespace : Str, revision : Str, created : Str, generator : Str }

	Manifest : {
		profile : Str,
		subject : Manifest.Subject,
		inventory_sha256 : Str,
		context : Manifest.Context,
		sidecars : List(Manifest.Entry),
	}

	## What a checker measured: the subject's bytes, the inventory file when
	## one was at hand, and each listed sidecar it found. A listed sidecar
	## missing from `sidecars` is absent.
	Observed : {
		subject : { sha256 : Str, size : U64 },
		inventory : [Measured(Str), Unmeasured],
		sidecars : List({ filename : Str, sha256 : Str, size : U64 }),
	}

	## The manifest of `subject` sits beside its sidecars as
	## `<subject>.sbom-manifest.json`.
	suffix = ".sbom-manifest.json"

	## The formats a listed sidecar may have: the renderings `bind` writes.
	formats = ["spdx-3.0.1", "spdx-2.3", "cyclonedx-1.7"]

	## The manifest's name for the format a sidecar reads back as
	## (`Profile.Document.version`).
	format_of : Str -> Try(Str, Str)
	format_of = |version|
		match version {
			"SPDX-3.0.1" => Ok("spdx-3.0.1")
			"SPDX-2.3" => Ok("spdx-2.3")
			"CycloneDX-1.7" => Ok("cyclonedx-1.7")
			other => Err("no manifest format for a ${other} document")
		}

	## The path of `name`, a file beside the manifest or subject at `path`:
	## what a manifest's file names resolve to.
	beside : Str, Str -> Str
	beside = |path, name| {
		directory = directory_of(path)
		if (
			(
				directory.is_empty(),
			)
		) name else if (directory == "/") "/${name}" else "${directory}/${name}"
	}

	## The last component of a path, on either separator: the name a manifest
	## records for it.
	file_name_of : Str -> Str
	file_name_of = |path| path.replace_each("\\", "/").split_on("/").last() ?? ""

	## The directory a path names, "" for a bare file name.
	directory_of : Str -> Str
	directory_of = |path| {
		parts = path.replace_each("\\", "/").split_on("/")
		leading = parts.take_first(parts.len() - 1)
		if (leading.is_empty()) "" else if (leading == [""]) "/" else Str.join_with(
			leading,
			"/",
		)
	}

	## The manifest as JSON text, one line with a trailing newline, keys in a
	## fixed order and sidecars by name, so the same evidence is the same
	## bytes. A manifest that `read` would refuse is not rendered.
	render : Manifest.Manifest -> Try(Str, Str)
	render = |manifest| {
		valid(manifest)?
		subject = manifest.subject
		context = manifest.context
		entry = |listed| JsonData.Object([
			member("filename", listed.filename),
			member("format", listed.format),
			member("sha256", listed.sha256),
			{ name: "size", value: JsonData.Number(listed.size.to_str()) },
		])
		tree = JsonData.Object([
			member("profile", manifest.profile),
			{
				name: "subject",
				value: JsonData.Object([
					member("filename", subject.filename),
					member("version", subject.version),
					member("target", subject.target),
					member("sha256", subject.sha256),
					{ name: "size", value: JsonData.Number(subject.size.to_str()) },
				]),
			},
			member("inventory_sha256", manifest.inventory_sha256),
			{
				name: "context",
				value: JsonData.Object([
					member("namespace", context.namespace),
					member("revision", context.revision),
					member("created", context.created),
					member("generator", context.generator),
				]),
			},
			{
				name: "sidecars",
				value: JsonData.Array(
					manifest.sidecars.sort_with(
						|a, b| Lookup.bytewise(
							a.filename,
							b.filename,
						),
					).map(entry),
				),
			},
		])
		text = "${JsonData.encode(tree).map_err(JsonData.message)?}\n"
		if leaks(text) {
			return Err("the manifest holds a developer path or credential")
		}
		Ok(text)
	}

	## A manifest from its text, refused unless it is one `render` writes:
	## this profile, files named by name only, lowercase SHA-256 digests, a
	## namespace ending in its revision, and at least one sidecar of a known
	## format, each listed once.
	read : Str -> Try(Manifest.Manifest, Str)
	read = |text| {
		if text.to_utf8().len() > 65536 {
			return Err("the manifest exceeds 64 KiB")
		}
		if leaks(text) {
			return Err("the manifest holds a developer path or credential")
		}
		decoded : Try(Manifest.Manifest, _)
		decoded = Json.parse(text)
		manifest = decoded.map_err(|_| "the manifest is not an evidence manifest")?
		valid(manifest)?
		Ok(manifest)
	}

	## The manifest, if what a checker measured is what it states: the
	## subject's digest and size, each listed sidecar present with its digest
	## and size, and the inventory's digest when one was measured.
	check : Str, Manifest.Observed -> Try(Manifest.Manifest, Str)
	check = |text, observed| {
		manifest = read(text)?
		if observed.subject.sha256 != manifest.subject.sha256 {
			return Err("the subject's bytes differ from what the manifest states")
		}
		if observed.subject.size != manifest.subject.size {
			return Err("the subject's size differs from what the manifest states")
		}
		for listed in manifest.sidecars {
			found = observed.sidecars
				.find_first(|entry| entry.filename == listed.filename)
				.map_err(|_| "the manifest lists ${listed.filename}, which is absent")?
			if found.sha256 != listed.sha256 {
				return Err("${listed.filename} differs from what the manifest states")
			}
			if found.size != listed.size {
				return Err(
					"the size of ${listed.filename} differs from what the manifest "
						.concat("states"),
				)
			}
		}
		match observed.inventory {
			Measured(digest) if digest != manifest.inventory_sha256 => Err(
				"the "
					.concat("inventory differs from the one the manifest states"),
			)
			_ => Ok(manifest)
		}
	}

	## A checked sidecar describes the manifest's subject: the same file name,
	## version and final digest. Named as `filename` in the manifest, it is
	## also in the format listed for it; "" names no listed sidecar.
	describes : Manifest.Manifest, Str, Sidecar.Checked -> Try({}, Str)
	describes = |manifest, filename, checked| {
		subject = checked.subject
		if subject.name != manifest.subject.filename or
			subject.version != manifest.subject.version or
				subject.sha256 != manifest.subject.sha256 {
			return Err(
				"the sidecar describes ${subject.name} ${subject.version}, not "
					.concat("the manifest's ${manifest.subject.filename} ")
					.concat("${manifest.subject.version}"),
			)
		}
		match manifest.sidecars.find_first(|entry| entry.filename == filename) {
			Ok(listed) => if (
				format_of(
					checked.document
						.version,
				) == Ok(
					listed
						.format,
				)
			) Ok(
				{},
			) else Err(
				"${filename} is a ${checked.document.version} document, not the "
					.concat("${listed.format} sidecar the manifest lists"),
			)
			Err(_) => Ok({})
		}
	}
}

member : Str, Str -> { name : Str, value : JsonData }
member = |name, value| { name, value: JsonData.String(value) }

valid : Manifest.Manifest -> Try({}, Str)
valid = |manifest| {
	subject = manifest.subject
	if ![Profile.profile, "blueprint-spdx-3.0-v1"].contains(manifest.profile) {
		return Err(
			"the manifest names profile ${manifest.profile}, not "
				.concat("${Profile.profile}"),
		)
	}
	if !file_name(subject.filename) {
		return Err("the manifest must name its subject by file name alone")
	}
	if subject.version.is_empty() or
		subject.target.is_empty() or
			!lowercase_sha256(subject.sha256) {
		return Err("the subject needs a version, a target and a lowercase SHA-256")
	}
	if !lowercase_sha256(manifest.inventory_sha256) {
		return Err("the inventory digest must be a lowercase SHA-256")
	}
	if manifest.context.revision.is_empty() or
		!manifest.context
			.namespace
			.ends_with("revision-${manifest.context.revision}") {
		return Err("namespace does not end with its revision")
	}
	if manifest.context.created.is_empty() or
		manifest.context.generator.is_empty() {
		return Err("the context needs a creation time and a generator")
	}
	if manifest.sidecars.is_empty() {
		return Err("the manifest lists no sidecar")
	}
	names = manifest.sidecars.map(|entry| entry.filename)
	if names.fold(
		[],
		|all, name| if (all.contains(name)) all else all.append(name),
	).len() != names.len() {
		return Err("the manifest lists a sidecar twice")
	}
	for entry in manifest.sidecars {
		if !file_name(entry.filename) or entry.filename == subject.filename {
			return Err(
				"the manifest must name each sidecar by file name alone, apart "
					.concat("from its subject"),
			)
		}
		if !Manifest.formats.contains(entry.format) {
			return Err(
				"${entry.filename} has format ${entry.format}, not one of "
					.concat("${Str.join_with(Manifest.formats, ", ")}"),
			)
		}
		if !lowercase_sha256(entry.sha256) {
			return Err("${entry.filename} needs a lowercase SHA-256")
		}
	}
	Ok({})
}

## A name within one directory: no separator, no parent reference.
file_name : Str -> Bool
file_name = |name| !name.is_empty() and
	name != "." and
		name != ".." and
			!name.contains("/") and
				!name.contains("\\")

lowercase_sha256 : Str -> Bool
lowercase_sha256 = |value| value.to_utf8().len() == 64 and
	value.to_utf8().all(
		|byte| (byte >= '0' and byte <= '9') or
			(byte >= 'a' and byte <= 'f'),
	)

leaks : Str -> Bool
leaks = |text| [
	"/Users/",
	"/home/",
	"/private/",
	"/tmp/",
	"/var/",
	"/nix/store/",
	"C:\\\\Users\\\\",
	"token=",
	"password=",
	"ghp_",
	"github_pat_",
	"BEGIN PRIVATE KEY",
].any(|marker| text.contains(marker))
