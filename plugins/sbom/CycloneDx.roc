# CycloneDX 1.7 JSON: what a BOM may hold, checked against the schema.
#
# Ported from roc-blueprint's blueprint-core/CycloneDx.roc: Copyright © 2026
# Luke Boswell and subsequent authors, under the Universal Permissive
# License (UPL), Version 1.0 (see LICENSE).
import JsonData
import Lookup
import SbomLicenses
import Spdx3

## CycloneDX 1.7 JSON, checked against the published schema
## (`schema/bom-1.7.schema.json` of CycloneDX/specification at 1.7.2)
## for the objects below.
##
## A BOM holds `bomFormat` "CycloneDX" and `specVersion` "1.7". Each object
## holds only its definition's properties, with the kinds, enumerations,
## patterns and required members the schema gives them. Beyond the schema
## this applies rules the specification states in prose: every `bom-ref` is
## unique within the BOM, a dependency names components by `bom-ref`, a
## license expression is a valid SPDX expression, a hash has its algorithm's
## length, and a serial number is an RFC 4122 URN. Services,
## vulnerabilities, formulation and the other top-level sections are outside
## this profile and rejected rather than skimmed.
CycloneDx := [].{
	format : Str
	format = "CycloneDX"

	version : Str
	version = "1.7"

	validate : Str -> Try(JsonData, Str)
	validate = |text| {
		tree = JsonData.decode_with(text, JsonData.documents)
			.map_err(JsonData.message)?
		CycloneDx.check(tree)?
		Ok(tree)
	}

	## `validate` for a document already parsed.
	check : JsonData -> Try({}, Str)
	check = |tree| {
		ignored = check_bom(tree, Strict)?
		if !ignored.is_empty() {
			return Err("outside this profile: ${Str.join_with(ignored, ", ")}")
		}
		Ok({})
	}

	## An RFC 4122 `urn:uuid:` serial number, which identifies a BOM.
	serial_number : Str -> Bool
	serial_number = |text| serial(text)

	## The CycloneDX versions an import reads. Each is checked against the 1.7
	## rules for what Blueprint reads, which earlier versions share.
	import_versions : List(Str)
	import_versions = ["1.4", "1.5", "1.6", "1.7"]

	## A BOM from elsewhere: the same checks as `check`, except that it may
	## name an earlier version, and members this profile does not read, such
	## as vulnerabilities, services or a component's pedigree, are named in
	## the result rather than refused. Their JSON kinds are still checked.
	check_import : JsonData -> Try(List(Str), Str)
	check_import = |tree| check_bom(tree, Lenient)

	## An RFC 3339 `date-time`, as the schema's format names it.
	date_time : Str -> Bool
	date_time = |text| {
		bytes = text.to_utf8()
		if bytes.len() < 20 {
			return False
		}
		base = Str.from_utf8_lossy(bytes.take_first(19))
		rest = Str.from_utf8_lossy(bytes.drop_first(19))
		zone = if rest.starts_with(".") {
			digits = rest.drop_prefix(".").to_utf8()
			count = digits.find_first_index(
				|byte| byte < '0' or
					byte > '9',
			) ?? digits.len()
			if (count == 0) "!" else Str.from_utf8_lossy(digits.drop_first(count))
		} else {
			rest
		}
		offset_ok = zone == "Z" or match zone.to_utf8() {
			[sign, h1, h2, ':', m1, m2] => (sign == '+' or sign == '-') and [
				h1,
				h2,
				m1,
				m2,
			].all(|byte| byte >= '0' and byte <= '9') and
				(h1 - '0') * 10 + (h2 - '0') <= 23 and
					(m1 - '0') * 10 + (m2 - '0') <= 59
			_ => False
		}
		offset_ok and Spdx3.timestamp("${base}Z")
	}

	## Each enumeration this profile checks, by its path in the schema's
	## `definitions` (`#/definitions/NAME`, then `properties` and `items`).
	vocabularies : List({ path : List(Str), values : List(Str) })
	vocabularies = [
		{ path: ["component", "type"], values: component_types },
		{ path: ["component", "scope"], values: scopes },
		{ path: ["hash-alg"], values: hash_algorithms },
		{ path: ["externalReference", "type"], values: reference_types },
	]

	## The members of each object this profile reads, by definition name, so a
	## test can hold them to the schema.
	objects : List({ definition : Str, members : List(Str) })
	objects = [
		"metadata",
		"component",
		"hash",
		"externalReference",
		"dependency",
		"compositions",
		"property",
		"organizationalEntity",
		"organizationalContact",
	].map(
		|name| {
			definition: name,
			members: (class(name) ?? []).map(|property| property.name),
		},
	)
}

Mode : [Strict, Lenient]

check_bom : JsonData, Mode -> Try(List(Str), Str)
check_bom = |tree, mode| {
	ignored = check_object(tree, "bom", mode)?
	spec = (tree.field("specVersion") ?? JsonData.Null).string() ?? ""
	versions = match mode {
		Strict => [CycloneDx.version]
		Lenient => CycloneDx.import_versions
	}
	if tree.field("bomFormat") != Ok(JsonData.String(CycloneDx.format)) or
		!versions.contains(spec) {
		return Err(
			"a BOM names bomFormat ${CycloneDx.format} and specVersion "
				.concat("${Str.join_with(versions, ", ")}"),
		)
	}
	refs = Lookup.index(bom_refs(tree).map(|ref| { key: ref, value: ref }))
	match Lookup.repeated(refs) {
		[] => {}
		[ref, ..] => return Err("duplicate bom-ref ${ref}")
	}
	for dependency in (
		tree.field("dependencies") ?? JsonData.Array([]),
	).array() ?? [] {
		named = [
			(dependency.field("ref") ?? JsonData.Null).string() ?? "",
		].concat(
			(
				(dependency.field("dependsOn") ?? JsonData.Array([])).array() ?? [],
			).map(|item| item.string() ?? ""),
		)
		for ref in named {
			if !Lookup.contains(refs, ref) {
				why = "which no component in the BOM declares"
				return Err("dependency names ${ref}, ${why}")
			}
		}
		depends = (
			(dependency.field("dependsOn") ?? JsonData.Array([])).array() ?? [],
		).map(|item| item.string() ?? "")
		if Lookup.repeated(
			Lookup.index(depends.map(|ref| { key: ref, value: ref })),
		) != [] {
			return Err("dependsOn repeats a reference")
		}
	}
	for composition in (
		tree.field("compositions") ?? JsonData.Array([]),
	).array() ?? [] {
		for aspect in ["assemblies", "dependencies"] {
			named = (
				(composition.field(aspect) ?? JsonData.Array([])).array() ?? [],
			).map(|item| item.string() ?? "")
			if named.any(|ref| !Lookup.contains(refs, ref)) or Lookup.repeated(
				Lookup.index(
					named.map(
						|ref| {
							key: ref,
							value: ref,
						},
					),
				),
			) != [] {
				return Err("composition has dangling or repeated component references")
			}
		}
	}
	dependents = (
		(tree.field("dependencies") ?? JsonData.Array([])).array() ?? [],
	).map(|dependency| (dependency.field("ref") ?? JsonData.Null).string() ?? "")
	if Lookup.repeated(
		Lookup.index(dependents.map(|ref| { key: ref, value: ref })),
	) != [] {
		return Err("two dependency entries name one component")
	}
	Ok(ignored)
}

component_types = [
	"application",
	"framework",
	"library",
	"container",
	"platform",
	"operating-system",
	"device",
	"device-driver",
	"firmware",
	"file",
	"machine-learning-model",
	"data",
	"cryptographic-asset",
]

scopes = ["required", "optional", "excluded"]

hash_algorithms = [
	"MD5",
	"SHA-1",
	"SHA-256",
	"SHA-384",
	"SHA-512",
	"SHA3-256",
	"SHA3-384",
	"SHA3-512",
	"BLAKE2b-256",
	"BLAKE2b-384",
	"BLAKE2b-512",
	"BLAKE3",
	"Streebog-256",
	"Streebog-512",
]

reference_types = [
	"vcs",
	"issue-tracker",
	"website",
	"advisories",
	"bom",
	"mailing-list",
	"social",
	"chat",
	"documentation",
	"support",
	"source-distribution",
	"distribution",
	"distribution-intake",
	"license",
	"build-meta",
	"build-system",
	"release-notes",
	"security-contact",
	"model-card",
	"log",
	"configuration",
	"evidence",
	"formulation",
	"attestation",
	"threat-model",
	"adversary-model",
	"risk-assessment",
	"vulnerability-assertion",
	"exploitability-statement",
	"pentest-report",
	"static-analysis-report",
	"dynamic-analysis-report",
	"runtime-analysis-report",
	"component-analysis-report",
	"maturity-report",
	"certification-report",
	"codified-infrastructure",
	"quality-metrics",
	"poam",
	"electronic-signature",
	"digital-signature",
	"rfc-9116",
	"patent",
	"patent-family",
	"patent-assertion",
	"citation",
	"other",
]

phases = [
	"design",
	"pre-build",
	"build",
	"post-build",
	"operations",
	"discovery",
	"decommission",
]

Kind : [
	Text,
	Bool,
	Integer,
	DateTime,
	Ref,
	Iri,
	Purl,
	Serial,
	Version,
	Expression,
	Enum(List(Str)),
	Inline(Str),
	Unsupported,
]

Property : { name : Str, kind : Kind, count : [One, Many], required : Bool }

one : Str, Kind -> Property
one = |name, kind| { name, kind, count: One, required: False }

many : Str, Kind -> Property
many = |name, kind| { name, kind, count: Many, required: False }

needs : Property -> Property
needs = |property| { ..property, required: True }

## The properties of each object, from the 1.7 schema's definitions. A
## property the schema allows but this profile does not read is Unsupported.
class : Str -> Try(List(Property), Str)
class = |name|
	match name {
		"bom" => Ok(
			[
				one("$schema", Text),
				needs(one("bomFormat", Enum(["CycloneDX"]))),
				needs(one("specVersion", Text)),
				one("serialNumber", Serial),
				one("version", Integer),
				one("metadata", Inline("metadata")),
				many("components", Inline("component")),
				many("dependencies", Inline("dependency")),
				many("compositions", Inline("compositions")),
				many("properties", Inline("property")),
			].concat(
				[
					"services",
					"externalReferences",
					"vulnerabilities",
					"annotations",
					"formulation",
					"declarations",
					"definitions",
					"citations",
					"signature",
				].map(|unread| one(unread, Unsupported)),
			),
		)
		"metadata" => Ok(
			[
				one("timestamp", DateTime),
				many("lifecycles", Inline("lifecycle")),
				one("tools", Inline("tools")),
				one("manufacturer", Inline("organizationalEntity")),
				many("authors", Inline("organizationalContact")),
				one("component", Inline("component")),
				one("supplier", Inline("organizationalEntity")),
				many("properties", Inline("property")),
			].concat(
				["manufacture", "licenses", "distributionConstraints"].map(
					|unread| one(
						unread,
						Unsupported,
					),
				),
			),
		)
		"lifecycle" => Ok([needs(one("phase", Enum(phases)))])
		"tools" => Ok([
			many("components", Inline("component")),
			one("services", Unsupported),
		])
		"component" => Ok(
			[
				needs(one("type", Enum(component_types))),
				one("mime-type", Text),
				one("bom-ref", Ref),
				one("supplier", Inline("organizationalEntity")),
				one("manufacturer", Inline("organizationalEntity")),
				many("authors", Inline("organizationalContact")),
				one("publisher", Text),
				one("group", Text),
				needs(one("name", Text)),
				one("version", Version),
				one("isExternal", Bool),
				one("description", Text),
				one("scope", Enum(scopes)),
				many("hashes", Inline("hash")),
				many("licenses", Inline("licenseChoice")),
				one("copyright", Text),
				one("cpe", Text),
				one("purl", Purl),
				many("externalReferences", Inline("externalReference")),
				many("components", Inline("component")),
				many("properties", Inline("property")),
			].concat(
				[
					"author",
					"versionRange",
					"patentAssertions",
					"omniborId",
					"swhid",
					"swid",
					"modified",
					"pedigree",
					"evidence",
					"releaseNotes",
					"modelCard",
					"data",
					"cryptoProperties",
					"tags",
					"signature",
				].map(|unread| one(unread, Unsupported)),
			),
		)
		"hash" => Ok([
			needs(one("alg", Enum(hash_algorithms))),
			needs(one("content", Text)),
		])
		"licenseChoice" => Ok(
			[
				one("expression", Expression),
				one("license", Inline("license")),
			].concat(
				[
					"expressionDetails",
					"acknowledgement",
					"bom-ref",
					"licensing",
					"properties",
				].map(|unread| one(unread, Unsupported)),
			),
		)
		"license" => Ok(
			[
				one("bom-ref", Ref),
				one("id", Text),
				one("name", Text),
				one("url", Iri),
				one("acknowledgement", Enum(["declared", "concluded"])),
			].concat(
				["text", "licensing", "properties"].map(
					|unread| one(
						unread,
						Unsupported,
					),
				),
			),
		)
		"tool" => Ok([
			one("vendor", Text),
			one("name", Text),
			one("version", Version),
			many("hashes", Inline("hash")),
			many("externalReferences", Inline("externalReference")),
		])
		"externalReference" => Ok([
			needs(one("url", Iri)),
			one("comment", Text),
			needs(one("type", Enum(reference_types))),
			many("hashes", Inline("hash")),
			many("properties", Inline("property")),
		])
		"compositions" => Ok([
			one("bom-ref", Ref),
			needs(
				one(
					"aggregate",
					Enum([
						"complete",
						"incomplete",
						"incomplete_first_party_only",
						"incomplete_first_party_proprietary_only",
						"incomplete_first_party_opensource_only",
						"incomplete_third_party_only",
						"incomplete_third_party_proprietary_only",
						"incomplete_third_party_opensource_only",
						"unknown",
						"not_specified",
					]),
				),
			),
			many("assemblies", Ref),
			many("dependencies", Ref),
			many("vulnerabilities", Unsupported),
			one("signature", Unsupported),
		])
		"dependency" => Ok([
			needs(one("ref", Ref)),
			many("dependsOn", Ref),
			many("provides", Unsupported),
		])
		"property" => Ok([needs(one("name", Text)), one("value", Text)])
		"organizationalEntity" => Ok([
			one("bom-ref", Ref),
			one("name", Text),
			many("url", Iri),
			many("contact", Inline("organizationalContact")),
			one("address", Unsupported),
		])
		"organizationalContact" => Ok([
			one("bom-ref", Ref),
			one("name", Text),
			one("email", Text),
			one("phone", Text),
		])
		_ => Err("CycloneDX object ${name} is outside this profile")
	}

## Check `tree` as the schema's `kind`, and name the members it holds that
## this profile does not read. Strict mode refuses those instead.
check_object : JsonData, Str, Mode -> Try(List(Str), Str)
check_object = |tree, kind, mode| {
	properties = class(kind)?
	match tree {
		Object(_) => {}
		_ => return Err("${kind} must be an object")
	}
	var $ignored = []
	for key in tree.keys() {
		match properties.find_first(|property| property.name == key) {
			Ok(property) =>
				match (property.kind, mode) {
					(
						Unsupported,
						Strict,
					) => return Err("${kind}.${key} is outside this profile")
					(Unsupported, Lenient) => {
						$ignored = $ignored.append("${kind}.${key}")
					}
					_ => {}
				}
			Err(_) => return Err(
				"${kind} has no property ${key} in CycloneDX "
					.concat("${CycloneDx.version}"),
			)
		}
	}
	for property in properties {
		match tree.field(property.name) {
			Err(_) =>
				if property.required {
					return Err("${kind} requires ${property.name}")
				}
			Ok(value) =>
				match (property.count, value) {
					(One, _) => {
						$ignored = $ignored.concat(
							check_value(
								value,
								property.kind,
								mode,
							).map_err(|problem| "${kind}.${property.name}: ${problem}")?,
						)
					}
					(Many, Array(values)) =>
						for item in values {
							$ignored = $ignored.concat(
								check_value(
									item,
									property.kind,
									mode,
								).map_err(|problem| "${kind}.${property.name}: ${problem}")?,
							)
						}
					(Many, _) => return Err("${kind}.${property.name} must be an array")
				}
		}
	}
	if kind == "hash" {
		algorithm = (tree.field("alg") ?? JsonData.Null).string() ?? ""
		content = (tree.field("content") ?? JsonData.Null).string() ?? ""
		expected = match algorithm {
			"MD5" => 32
			"SHA-1" => 40
			"SHA-256" | "SHA3-256" | "BLAKE2b-256" | "BLAKE3" | "Streebog-256" => 64
			"SHA-384" | "SHA3-384" | "BLAKE2b-384" => 96
			_ => 128
		}
		if content.to_utf8().len() != expected or
			!content.to_utf8().all(
				|byte| (byte >= '0' and byte <= '9') or
					(byte >= 'a' and byte <= 'f') or
						(byte >= 'A' and byte <= 'F'),
			) {
			return Err("${algorithm} hash is not ${expected.to_str()} hex digits")
		}
	}
	# A license choice is an expression or a license; a license has an id or a
	# name.
	if kind == "licenseChoice" and
		tree.field("expression").is_ok() == tree.field("license").is_ok() {
		return Err("a license choice holds exactly one of expression and license")
	}
	if kind == "license" and
		tree.field("id").is_ok() == tree.field("name").is_ok() {
		return Err("a license holds exactly one of id and name")
	}
	if kind == "license" {
		id = (tree.field("id") ?? JsonData.Null).string() ?? ""
		listed = id.is_empty() or
			SbomLicenses.licenses.contains(id) or
				SbomLicenses.exceptions.contains(id)
		match (listed, mode) {
			(True, _) => {}
			(
				False,
				Strict,
			) => return Err("license id ${id} is not in the SPDX License List")
			(False, Lenient) => {
				outside = "outside SPDX License List 3.26"
				$ignored = $ignored.append("license id ${id} ${outside}")
			}
		}
	}
	Ok($ignored)
}

check_value : JsonData, Kind, Mode -> Try(List(Str), Str)
check_value = |value, kind, mode| {
	ok = Ok([])
	match (kind, value) {
		(Text, String(_)) => ok
		(Bool, Boolean(_)) => ok
		# JSON Schema draft-07 counts any number with no fractional part as an
		# integer.
		(Integer, Number(lexeme)) => if (JsonData.whole(lexeme) and
			lexeme != "0" and
				!lexeme.starts_with("0.")) ok else Err("not an integer of at least 1")
		(
			DateTime,
			String(text),
		) => if (CycloneDx.date_time(text)) ok else Err("not an RFC 3339 date-time")
		(Ref, String(text)) => if (!text.is_empty() and
			!text.starts_with("urn:cdx:")) ok else Err(
			"a bom-ref is non-empty and is "
				.concat("not a BOM-Link"),
		)
		(Iri, String(text)) => if (
			!text.is_empty() and
				!text.to_utf8().any(
					|byte| byte <= ' ' or
						byte == delete,
				)
		) ok else Err("not an IRI reference")
		(Purl, String(text)) => if (text.starts_with("pkg:") and
			text.drop_prefix("pkg:").contains("/") and
				!text.to_utf8().any(|byte| byte <= ' ')) ok else Err("not a package URL")
		(
			Serial,
			String(text),
		) => if (serial(text)) ok else Err("not a urn:uuid serial number")
		(Version, String(text)) => if (
			text.to_utf8()
				.len() <= 1024
		) ok else Err("version longer than 1024 bytes")
		(
			Expression,
			String(text),
		) => if (
			(
				SbomLicenses.expression(text),
			)
		) ok else Err("invalid SPDX license expression ${Json.to_str(text)}")
		(
			Enum(allowed),
			String(text),
		) => if (
			(
				allowed.contains(text),
			)
		) ok else Err("${text} is not a permitted value")
		# Tools are an object since 1.5, and a legacy array of tool records before.
		(Inline("tools"), Array(items)) => items.fold(
			ok,
			|result, item| match result {
				Ok(found) => check_object(
					item,
					"tool",
					mode,
				).map_ok(|more| found.concat(more))
				Err(problem) => Err(problem)
			},
		)
		(Inline(name), _) => check_object(value, name, mode)
		# A member this profile does not read still has to be JSON of some kind.
		(Unsupported, _) => ok
		_ => Err("wrong JSON kind")
	}
}

## The schema's pattern `^urn:uuid:` then 8-4-4-4-12 lowercase hex digits.
serial : Str -> Bool
serial = |text|
	match text.drop_prefix("urn:uuid:").split_on("-") {
		[a, b, c, d, e] if text.starts_with("urn:uuid:") => [
			(a, 8),
			(b, 4),
			(c, 4),
			(d, 4),
			(e, 12),
		].all(
			|(group, len)| group.to_utf8().len() == len and
				group.to_utf8().all(
					|byte| (byte >= '0' and byte <= '9') or
						(byte >= 'a' and byte <= 'f'),
				),
		)
		_ => False
	}

## Every `bom-ref` the BOM declares, wherever it is.
bom_refs : JsonData -> List(Str)
bom_refs = |tree|
	match tree {
		Object(members) => members.fold(
			[],
			|all, member|
				all.concat(
					match member.name {
						"bom-ref" => [member.value.string() ?? ""]
						"dependencies" | "properties" => []
						_ => bom_refs(member.value)
					},
				),
		)
		Array(items) => items.fold([], |all, item| all.concat(bom_refs(item)))
		_ => []
	}

minimal : Str
minimal = "{\"bomFormat\":\"CycloneDX\",\"specVersion\":\"1.7\",\"serialNumbe"
	.concat("r\":\"urn:uuid:3e671687-395b-41f5-a30f-a58921a69b79\",\"version\":1")
	.concat(",\"metadata\":{\"timestamp\":\"2026-10-21T00:00:00Z\",\"component\":")
	.concat("{\"type\":\"file\",\"bom-ref\":\"Subject\",\"name\":\"a\",\"hashes\"")
	.concat(":[{\"alg\":\"SHA-256\",\"content\"")
	.concat(":\"${Str.join_with(List.repeat("a", 64), "")}\"}]}},\"components\":[")
	.concat("{\"type\":\"library\",\"bom-ref\":\"p\",\"name\":\"p\",\"licenses\":")
	.concat("[{\"expression\":\"MIT\"}],\"purl\":\"pkg:generic/p@1\"}],\"dependen")
	.concat("cies\":[{\"ref\":\"Subject\",\"dependsOn\":[\"p\"]},")
	.concat("{\"ref\":\"p\"}]}")

# The minimal CycloneDX 1.7 BOM is valid.
expect CycloneDx.validate(minimal).is_ok()
# Another specVersion is refused.
expect CycloneDx.validate(minimal.replace_each("\"1.7\"", "\"1.6\"")).is_err()
# A dependency on an undeclared component is refused.
expect CycloneDx.validate(
	minimal.replace_each(
		"\"dependsOn\":[\"p\"]",
		"\"dependsOn\":[\"q\"]",
	),
).is_err()
# A repeated dependency is refused.
expect CycloneDx.validate(
	minimal.replace_each(
		"\"dependsOn\":[\"p\"]",
		"\"dependsOn\":[\"p\",\"p\"]",
	),
).is_err()
# A component cannot take the subject's bom-ref.
expect CycloneDx.validate(
	minimal.replace_each(
		"\"bom-ref\":\"p\"",
		"\"bom-ref\":\"Subject\"",
	),
).is_err()
# A malformed license expression is refused.
expect CycloneDx.validate(minimal.replace_each("\"MIT\"", "\"MIT OR\""))
	.is_err()
# An empty hash is refused.
expect CycloneDx.validate(
	minimal.replace_each(
		"\"content\":\"a",
		"\"content\":\"",
	),
).is_err()
# An unknown component type is refused.
expect CycloneDx.validate(
	minimal.replace_each(
		"\"type\":\"library\"",
		"\"type\":\"crate\"",
	),
).is_err()
# The BOM version starts at 1.
expect CycloneDx.validate(
	minimal.replace_each("\"version\":1", "\"version\":0"),
)
	.is_err()
# The BOM version is an integer.
expect CycloneDx.validate(
	minimal.replace_each(
		"\"version\":1",
		"\"version\":1.5",
	),
).is_err()
# A serial number is a lowercase UUID URN.
expect CycloneDx.validate(
	minimal.replace_each("urn:uuid:3e67", "urn:uuid:3E67"),
)
	.is_err()
# A pedigree is outside the profile.
expect CycloneDx.validate(minimal.replace_each("\"purl\"", "\"pedigree\""))
	.is_err()
# Services are outside the profile.
expect CycloneDx.validate(
	minimal.replace_each(
		"\"components\":[",
		"\"services\":[],\"components\":[",
	),
).is_err()
# Timestamps are RFC 3339 date-times.
expect CycloneDx.date_time("2026-10-21T00:00:00Z") and
	CycloneDx.date_time("2026-10-21T10:00:00.25+10:00") and
		!CycloneDx.date_time("2026-10-21T00:00:00") and
			!CycloneDx.date_time("2026-02-30T00:00:00Z") and
				!CycloneDx.date_time("2026-10-21T00:00:00.Z")

## The ASCII delete character, which no URI or name may hold.
delete : U8
delete = 127
