# SPDX 2.3 and 2.2 JSON: what a document may hold, checked against the model.
#
# Ported from roc-blueprint's blueprint-core/Spdx2.roc: Copyright © 2026
# Luke Boswell and subsequent authors, under the Universal Permissive
# License (UPL), Version 1.0 (see LICENSE).
import JsonData
import Lookup
import SbomLicenses
import Spdx3

## SPDX 2.2 and 2.3 JSON, checked against the property sets, required members,
## enumerations and identifier syntax of the SPDX 2.3 JSON schema
## (tests/sbom/schema/spdx-2.3.schema.json), with 2.2's extra required package
## members. It also applies the specification's prose rules: an `SPDXRef-`
## identifier is unique, a relationship names elements in the document, a
## `LicenseRef-` in a license expression is declared in
## `hasExtractedLicensingInfos`, a checksum has its algorithm's length, and
## creators and suppliers use the `Person:`/`Organization:`/`Tool:` syntax, a
## snippet and a package's files name files in the document, and an external
## `DocumentRef-` is declared before a relationship uses it.
##
## Every section of the 2.3 schema is checked, files and snippets included.
## What Blueprint imports from a valid document is the reader's choice, and it
## records what it leaves out.
Spdx2 := [].{
	versions : List(Str)
	versions = ["SPDX-2.2", "SPDX-2.3"]

	## Each enumeration this profile checks, by its path through the vendored
	## schema's `properties` and `items` (tests/sbom/schema/spdx-2.3.schema.json).
	vocabularies : List({ path : List(Str), values : List(Str) })
	vocabularies = [
		{ path: ["relationships", "relationshipType"], values: relationship_types },
		{ path: ["packages", "checksums", "algorithm"], values: checksum_algorithms },
		{
			path: ["packages", "externalRefs", "referenceCategory"],
			values: reference_categories,
		},
		{ path: ["packages", "primaryPackagePurpose"], values: purposes },
		{ path: ["annotations", "annotationType"], values: annotation_types },
		{ path: ["files", "fileTypes"], values: file_types },
	]

	## The members of each object this profile reads, by their path through the
	## schema, as for `vocabularies`.
	objects : List({ path : List(Str), members : List(Str) })
	objects = [
		{ path: [], members: class("document").map(|property| property.name) },
		{
			path: ["creationInfo"],
			members: class("creationInfo").map(|property| property.name),
		},
		{
			path: ["packages"],
			members: class("package").map(|property| property.name),
		},
		{
			path: ["relationships"],
			members: class("relationship").map(|property| property.name),
		},
		{
			path: ["annotations"],
			members: class("annotation").map(|property| property.name),
		},
		{
			path: ["packages", "checksums"],
			members: class("checksum").map(|property| property.name),
		},
		{
			path: ["packages", "externalRefs"],
			members: class("externalRef").map(|property| property.name),
		},
		{
			path: ["hasExtractedLicensingInfos"],
			members: class("extractedLicense").map(|property| property.name),
		},
		{
			path: ["packages", "packageVerificationCode"],
			members: class("verificationCode").map(|property| property.name),
		},
		{ path: ["files"], members: class("file").map(|property| property.name) },
		{
			path: ["snippets"],
			members: class("snippet").map(|property| property.name),
		},
		{
			path: ["snippets", "ranges"],
			members: class("range").map(|property| property.name),
		},
		{
			path: ["externalDocumentRefs"],
			members: class("externalDocumentRef").map(|property| property.name),
		},
		{
			path: ["revieweds"],
			members: class("reviewed").map(|property| property.name),
		},
		{
			path: ["hasExtractedLicensingInfos", "crossRefs"],
			members: class("crossRef").map(|property| property.name),
		},
	]

	validate : JsonData -> Try({}, Str)
	validate = |tree| {
		check_object(tree, "document")?
		version = (tree.field("spdxVersion") ?? JsonData.Null).string() ?? ""
		if !versions.contains(version) {
			return Err("spdxVersion must be one of ${Str.join_with(versions, ", ")}")
		}
		if tree.field("SPDXID") != Ok(JsonData.String("SPDXRef-DOCUMENT")) or
			tree.field("dataLicense") != Ok(JsonData.String("CC0-1.0")) {
			return Err("an SPDX 2 document is SPDXRef-DOCUMENT under CC0-1.0")
		}
		entries = (tree.field("packages") ?? JsonData.Array([])).array() ?? []
		listed = |key| (tree.field(key) ?? JsonData.Array([])).array() ?? []
		spdx_id = |element| (element.field("SPDXID") ?? JsonData.Null).string() ?? ""
		file_ids = listed("files").map(spdx_id)
		ids = entries.map(spdx_id)
			.concat(file_ids)
			.concat(listed("snippets").map(spdx_id))
		seen = Lookup.index(ids.map(|id| { key: id, value: id }))
		match Lookup.repeated(seen) {
			[] => {}
			[id, ..] => return Err("duplicate SPDX identifier ${id}")
		}
		if Lookup.contains(seen, "SPDXRef-DOCUMENT") {
			return Err("an element cannot be SPDXRef-DOCUMENT")
		}
		external = listed("externalDocumentRefs").map(
			|reference| (
				reference.field("externalDocumentId") ?? JsonData.Null,
			).string() ?? "",
		)
		bad_ref = |id| !id.starts_with("DocumentRef-") or id == "DocumentRef-"
		if external.any(bad_ref) or

			external.len() != external.fold(
				[],
				|all, id| if (all.contains(id)) all else all.append(id),
			).len() {
			return Err("externalDocumentId must be a unique DocumentRef- identifier")
		}
		files = Lookup.index(file_ids.map(|id| { key: id, value: id }))
		for snippet in listed("snippets") {
			from_file = (
				snippet.field("snippetFromFile") ?? JsonData.Null,
			).string() ?? ""
			pointers = (
				(snippet.field("ranges") ?? JsonData.Array([])).array() ?? [],
			).fold(
				[],
				|all, range| all.concat(
					[
						"startPointer",
						"endPointer",
					].map(
						|end| (
							(range.field(end) ?? JsonData.Null).field("reference") ?? JsonData.Null,
						).string() ?? "",
					),
				),
			)
			if !Lookup.contains(files, from_file) or pointers.any(
				|reference| !Lookup.contains(
					files,
					reference,
				),
			) {
				return Err("a snippet names a file outside the document")
			}
		}
		named = |id| Lookup.contains(seen, id) or match id.split_on(":") {
			[document, element] => external.contains(document) and spdx_ref(element)
			_ => False
		}
		declared = (
			(
				tree.field("hasExtractedLicensingInfos") ?? JsonData.Array([]),
			).array() ?? [],
		).map(|info| (info.field("licenseId") ?? JsonData.Null).string() ?? "")
		for entry in entries {
			if version == "SPDX-2.2" and [
				"licenseConcluded",
				"licenseDeclared",
				"copyrightText",
			].any(|name| entry.field(name).is_err()) {
				return Err(
					"SPDX-2.2 packages require licenseConcluded, licenseDeclared "
						.concat("and copyrightText"),
				)
			}
			for name in ["licenseConcluded", "licenseDeclared"] {
				expression = (
					entry.field(name) ?? JsonData.String("NOASSERTION"),
				).string() ?? ""
				if SbomLicenses.custom_ids(expression).any(|id| !declared.contains(id)) {
					return Err(
						"${name} names a LicenseRef- that hasExtractedLicensingInfos "
							.concat("does not declare"),
					)
				}
			}
			if ((entry.field("hasFiles") ?? JsonData.Array([])).array() ?? []).any(
				|file| !Lookup.contains(
					files,
					file.string() ?? "",
				),
			) {
				return Err("hasFiles names a file outside the document")
			}
		}
		for relationship in (
			tree.field("relationships") ?? JsonData.Array([]),
		).array() ?? [] {
			from = (relationship.field("spdxElementId") ?? JsonData.Null).string() ?? ""
			to = (
				relationship.field("relatedSpdxElement") ?? JsonData.Null,
			).string() ?? ""
			if (from != "SPDXRef-DOCUMENT" and !named(from)) or
				(to != "SPDXRef-DOCUMENT" and
					to != "NONE" and
						to != "NOASSERTION" and
							!named(to)) {
				return Err(
					"relationship names an element outside the document: ${from} "
						.concat("-> ${to}"),
				)
			}
		}
		for described in (
			tree.field("documentDescribes") ?? JsonData.Array([]),
		).array() ?? [] {
			if !Lookup.contains(seen, described.string() ?? "") {
				return Err("documentDescribes names an element outside the document")
			}
		}
		Ok({})
	}
}

Kind : [
	Text,
	Bool,
	Integer,
	Date,
	Uri,
	Download,
	Enum(List(Str)),
	SpdxRef,
	Expression,
	Agent,
	Creator,
	ListVersion,
	Inline(Str),
	Unsupported,
]

Property : {
	name : Str,
	kind : Kind,
	count : [One, Many(U64)],
	required : Bool,
}

one : Str, Kind -> Property
one = |name, kind| { name, kind, count: One, required: False }

many : Str, Kind -> Property
many = |name, kind| { name, kind, count: Many(0), required: False }

needs : Property -> Property
needs = |property| { ..property, required: True }

annotation_types = ["OTHER", "REVIEW"]

reference_categories = [
	"OTHER",
	"PERSISTENT-ID",
	"PERSISTENT_ID",
	"SECURITY",
	"PACKAGE-MANAGER",
	"PACKAGE_MANAGER",
]

file_types = [
	"OTHER",
	"DOCUMENTATION",
	"IMAGE",
	"VIDEO",
	"ARCHIVE",
	"SPDX",
	"APPLICATION",
	"SOURCE",
	"BINARY",
	"TEXT",
	"AUDIO",
]

purposes = [
	"OTHER",
	"INSTALL",
	"ARCHIVE",
	"FIRMWARE",
	"APPLICATION",
	"FRAMEWORK",
	"LIBRARY",
	"CONTAINER",
	"SOURCE",
	"DEVICE",
	"OPERATING-SYSTEM",
	"FILE",
]

annotation_props = [
	needs(one("annotationDate", Date)),
	needs(one("annotationType", Enum(annotation_types))),
	needs(one("annotator", Creator)),
	needs(one("comment", Text)),
]

relationship_types = [
	"VARIANT_OF",
	"COPY_OF",
	"PATCH_FOR",
	"TEST_DEPENDENCY_OF",
	"CONTAINED_BY",
	"DATA_FILE_OF",
	"OPTIONAL_COMPONENT_OF",
	"ANCESTOR_OF",
	"GENERATES",
	"CONTAINS",
	"OPTIONAL_DEPENDENCY_OF",
	"FILE_ADDED",
	"REQUIREMENT_DESCRIPTION_FOR",
	"DEV_DEPENDENCY_OF",
	"DEPENDENCY_OF",
	"BUILD_DEPENDENCY_OF",
	"DESCRIBES",
	"PREREQUISITE_FOR",
	"HAS_PREREQUISITE",
	"PROVIDED_DEPENDENCY_OF",
	"DYNAMIC_LINK",
	"DESCRIBED_BY",
	"METAFILE_OF",
	"DEPENDENCY_MANIFEST_OF",
	"PATCH_APPLIED",
	"RUNTIME_DEPENDENCY_OF",
	"TEST_OF",
	"TEST_TOOL_OF",
	"DEPENDS_ON",
	"SPECIFICATION_FOR",
	"FILE_MODIFIED",
	"DISTRIBUTION_ARTIFACT",
	"AMENDS",
	"DOCUMENTATION_OF",
	"GENERATED_FROM",
	"STATIC_LINK",
	"OTHER",
	"BUILD_TOOL_OF",
	"TEST_CASE_OF",
	"PACKAGE_OF",
	"DESCENDANT_OF",
	"FILE_DELETED",
	"EXPANDED_FROM_ARCHIVE",
	"DEV_TOOL_OF",
	"EXAMPLE_OF",
]

checksum_algorithms = [
	"SHA1",
	"BLAKE3",
	"SHA3-384",
	"SHA256",
	"SHA384",
	"BLAKE2b-512",
	"BLAKE2b-256",
	"SHA3-512",
	"MD2",
	"ADLER32",
	"MD4",
	"SHA3-256",
	"BLAKE2b-384",
	"SHA512",
	"MD6",
	"MD5",
	"SHA224",
]

## The members of each object kind, from the SPDX 2.3 JSON schema.
class : Str -> List(Property)
class = |name|
	match name {
		"document" => [
			one("$schema", Text),
			needs(one("SPDXID", SpdxRef)),
			many("annotations", Inline("annotation")),
			one("comment", Text),
			needs(one("creationInfo", Inline("creationInfo"))),
			needs(one("dataLicense", Text)),
			many("documentDescribes", SpdxRef),
			needs(one("documentNamespace", Uri)),
			many("externalDocumentRefs", Inline("externalDocumentRef")),
			many("files", Inline("file")),
			many("hasExtractedLicensingInfos", Inline("extractedLicense")),
			needs(one("name", Text)),
			many("packages", Inline("package")),
			many("relationships", Inline("relationship")),
			many("revieweds", Inline("reviewed")),
			many("snippets", Inline("snippet")),
			needs(one("spdxVersion", Text)),
		]
		"creationInfo" => [
			one("comment", Text),
			needs(one("created", Date)),
			needs({ ..many("creators", Creator), count: Many(1) }),
			one("licenseListVersion", ListVersion),
		]
		"package" => [
			needs(one("SPDXID", SpdxRef)),
			many("annotations", Inline("annotation")),
			many("attributionTexts", Text),
			one("builtDate", Date),
			many("checksums", Inline("checksum")),
			one("comment", Text),
			one("copyrightText", Text),
			one("description", Text),
			needs(one("downloadLocation", Download)),
			many("externalRefs", Inline("externalRef")),
			one("filesAnalyzed", Bool),
			many("hasFiles", SpdxRef),
			one("homepage", Download),
			one("licenseComments", Text),
			one("licenseConcluded", Expression),
			one("licenseDeclared", Expression),
			many("licenseInfoFromFiles", Expression),
			needs(one("name", Text)),
			one("originator", Agent),
			one("packageFileName", Text),
			one("packageVerificationCode", Inline("verificationCode")),
			one("primaryPackagePurpose", Enum(purposes)),
			one("releaseDate", Date),
			one("sourceInfo", Text),
			one("summary", Text),
			one("supplier", Agent),
			one("validUntilDate", Date),
			one("versionInfo", Text),
		]
		"relationship" => [
			one("comment", Text),
			needs(one("relatedSpdxElement", Text)),
			needs(one("relationshipType", Enum(relationship_types))),
			needs(one("spdxElementId", SpdxRef)),
		]
		"annotation" => annotation_props
		"checksum" => [
			needs(one("algorithm", Enum(checksum_algorithms))),
			needs(one("checksumValue", Text)),
		]
		"externalRef" => [
			one("comment", Text),
			needs(one("referenceCategory", Enum(reference_categories))),
			needs(one("referenceLocator", Text)),
			needs(one("referenceType", Text)),
		]
		"extractedLicense" => [
			one("comment", Text),
			many("crossRefs", Inline("crossRef")),
			needs(one("extractedText", Text)),
			needs(one("licenseId", Text)),
			one("name", Text),
			many("seeAlsos", Text),
		]
		"crossRef" => [
			one("isLive", Bool),
			one("isValid", Bool),
			one("isWayBackLink", Bool),
			one("match", Text),
			one("order", Integer),
			one("timestamp", Text),
			needs(one("url", Text)),
		]
		"file" => [
			needs(one("SPDXID", SpdxRef)),
			many("annotations", Inline("annotation")),
			one("artifactOfs", Unsupported),
			many("attributionTexts", Text),
			needs({ ..many("checksums", Inline("checksum")), count: Many(1) }),
			one("comment", Text),
			one("copyrightText", Text),
			many("fileContributors", Text),
			many("fileDependencies", Text),
			needs(one("fileName", Text)),
			many("fileTypes", Enum(file_types)),
			one("licenseComments", Text),
			one("licenseConcluded", Expression),
			many("licenseInfoInFiles", Expression),
			one("noticeText", Text),
		]
		"snippet" => [
			needs(one("SPDXID", SpdxRef)),
			many("annotations", Inline("annotation")),
			many("attributionTexts", Text),
			one("comment", Text),
			one("copyrightText", Text),
			one("licenseComments", Text),
			one("licenseConcluded", Expression),
			many("licenseInfoInSnippets", Expression),
			one("name", Text),
			needs({ ..many("ranges", Inline("range")), count: Many(1) }),
			needs(one("snippetFromFile", SpdxRef)),
		]
		"range" => [
			needs(one("endPointer", Inline("pointer"))),
			needs(one("startPointer", Inline("pointer"))),
		]
		"pointer" => [
			one("lineNumber", Integer),
			one("offset", Integer),
			needs(one("reference", Text)),
		]
		"externalDocumentRef" => [
			needs(one("checksum", Inline("checksum"))),
			needs(one("externalDocumentId", Text)),
			needs(one("spdxDocument", Uri)),
		]
		"reviewed" => [
			one("comment", Text),
			needs(one("reviewDate", Date)),
			one("reviewer", Text),
		]
		"verificationCode" => [
			many("packageVerificationCodeExcludedFiles", Text),
			needs(one("packageVerificationCodeValue", Text)),
		]
		_ => []
	}

check_object : JsonData, Str -> Try({}, Str)
check_object = |tree, kind| {
	properties = class(kind)
	match tree {
		Object(_) => {}
		_ => return Err("${kind} must be an object")
	}
	for key in tree.keys() {
		match properties.find_first(|property| property.name == key) {
			Ok(property) => match property.kind {
				Unsupported => return Err("${kind}.${key} is outside this profile")
				_ => {}
			}
			Err(_) => return Err("${kind} has no member ${key} in SPDX 2.3")
		}
	}
	for property in properties {
		match tree.field(property.name) {
			Err(_) => if property.required {
				return Err("${kind} requires ${property.name}")
			}
			Ok(value) => match (property.count, value) {
				(
					One,
					_,
				) => check_value(
					value,
					property.kind,
				).map_err(|problem| "${kind}.${property.name}: ${problem}")?
				(Many(min), Array(values)) => {
					if values.len() < min {
						return Err(
							"${kind}.${property.name} needs at least ${min.to_str()} "
								.concat("values"),
						)
					}
					for item in values {
						check_value(
							item,
							property.kind,
						).map_err(|problem| "${kind}.${property.name}: ${problem}")?
					}
				}
				(Many(_), _) => return Err("${kind}.${property.name} must be an array")
			}
		}
	}
	if kind == "checksum" {
		algorithm = (tree.field("algorithm") ?? JsonData.Null).string() ?? ""
		value = (tree.field("checksumValue") ?? JsonData.Null).string() ?? ""
		expected = match algorithm {
			"MD2" | "MD4" | "MD5" => 32
			"SHA1" => 40
			"SHA224" | "SHA3-224" => 56
			"SHA256" | "SHA3-256" | "BLAKE2b-256" | "BLAKE3" => 64
			"SHA384" | "SHA3-384" | "BLAKE2b-384" => 96
			"SHA512" | "SHA3-512" | "BLAKE2b-512" => 128
			"ADLER32" => 8
			_ => 0
		}
		if (expected > 0 and value.to_utf8().len() != expected) or
			!value.to_utf8().all(
				|byte| (byte >= '0' and byte <= '9') or
					(byte >= 'a' and byte <= 'f'),
			) {
			return Err(
				"${algorithm} checksum is not ${expected.to_str()} lowercase "
					.concat("hex digits"),
			)
		}
	}
	Ok({})
}

check_value : JsonData, Kind -> Try({}, Str)
check_value = |value, kind|
	match (kind, value) {
		(Text, String(_)) => Ok({})
		(Bool, Boolean(_)) => Ok({})
		(
			Integer,
			Number(lexeme),
		) => if (JsonData.whole(lexeme)) Ok({}) else Err("not a non-negative integer")
		(
			Date,
			String(text),
		) => if (Spdx3.timestamp(text)) Ok({}) else Err("not a UTC timestamp")
		(Uri, String(text)) => if (
			text.contains(":") and
				!text.contains("#") and
					!text.to_utf8()
						.any(|byte| byte <= ' ')
		) Ok({}) else Err("not an absolute URI without a fragment")
		(Download, String(text)) => if (
			text == "NONE" or
				text == "NOASSERTION" or
					(
						text.contains(":") and
							!text.to_utf8()
								.any(|byte| byte <= ' ')
					)
		) Ok({}) else Err("not a location, NONE or NOASSERTION")
		(
			Enum(allowed),
			String(text),
		) => if (
			(
				allowed.contains(text),
			)
		) Ok({}) else Err("${text} is not a permitted value")
		(
			SpdxRef,
			String(text),
		) => if (
			(
				spdx_ref(text),
			)
		) Ok({}) else Err("${text} is not an SPDXRef- identifier")
		(Expression, String(text)) => if (text == "NONE" or
			text == "NOASSERTION" or
				SbomLicenses.expression(text)) Ok(
			{},
		) else Err("invalid license expression ${Json.to_str(text)}")
		(Agent, String(text)) => if (
			text == "NOASSERTION" or agent(
				text,
				["Person: ", "Organization: "],
			)
		) Ok({}) else Err("not a Person: or Organization: agent")
		(Creator, String(text)) => if (
			agent(
				text,
				["Person: ", "Organization: ", "Tool: "],
			)
		) Ok({}) else Err("not a Person:, Organization: or Tool: creator")
		(ListVersion, String(text)) => match text.split_on(".") {
			[major, minor] if !major.is_empty() and
				!minor.is_empty() and
					major.to_utf8().all(|byte| byte >= '0' and byte <= '9') and
						minor.to_utf8().all(|byte| byte >= '0' and byte <= '9') => Ok({})
			_ => Err("license list version must be MAJOR.MINOR")
		}
		(Inline(name), _) => check_object(value, name)
		_ => Err("wrong JSON kind")
	}

spdx_ref : Str -> Bool
spdx_ref = |text| text.starts_with("SPDXRef-") and
	text != "SPDXRef-" and
		text.to_utf8().all(
			|byte| (byte >= 'a' and byte <= 'z') or
				(byte >= 'A' and byte <= 'Z') or
					(byte >= '0' and byte <= '9') or
						byte == '-' or
							byte == '.',
		)

agent : Str, List(Str) -> Bool
agent = |text, prefixes| prefixes.any(
	|prefix| text.starts_with(prefix) and
		text != prefix,
)

minimal : Str
minimal = "{\"spdxVersion\":\"SPDX-2.3\",\"dataLicense\":\"CC0-1.0\",\"SPDXI"
	.concat("D\":\"SPDXRef-DOCUMENT\",\"name\":\"d\",\"documentNamespace\":\"http")
	.concat("s://e.org/d\",\"creationInfo\":{\"created\":\"2026-10-21T00:00:00Z\"")
	.concat(",\"creators\":[\"Tool: ")
	.concat("t\"]},\"packages\":[{\"SPDXID\":\"SPDXRef-p\",\"name\":\"p\",\"downl")
	.concat("oadLocation\":\"NOASSERTION\",\"licenseDeclared\":\"MIT\",\"checksum")
	.concat("s\":[{\"algorithm\":\"SHA256\",\"checksumValue\"")
	.concat(":\"${Str.join_with(List.repeat("a", 64), "")}\"}]}],\"relationship")
	.concat("s\":[{\"spdxElementId\":\"SPDXRef-DOCUMENT\",\"relatedSpdxElement\"")
	.concat(":\"SPDXRef-p\",\"relationshipType\":\"DESCRIBES\"}]}")

check : Str -> Try({}, Str)
check = |text| Spdx2.validate(
	JsonData.decode_with(text, JsonData.documents).map_err(JsonData.message)?,
)

# The minimal SPDX 2.3 document is valid.
expect check(minimal).is_ok()
# SPDX 2.2 needs fields this document leaves out.
expect check(minimal.replace_each("SPDX-2.3", "SPDX-2.2")).is_err()
# SPDX 2.1 is not read.
expect check(minimal.replace_each("SPDX-2.3", "SPDX-2.1")).is_err()
# A relationship to an undeclared element is refused.
expect check(
	minimal.replace_each(
		"\"relatedSpdxElement\":\"SPDXRef-p\"",
		"\"relatedSpdxElement\":\"SPDXRef-q\"",
	),
).is_err()
# A LicenseRef- needs an extracted licensing info.
expect check(minimal.replace_each("\"MIT\"", "\"LicenseRef-x\"")).is_err()
# versionInfo must be a string.
expect check(
	minimal.replace_each(
		"\"name\":\"p\"",
		"\"name\":\"p\",\"versionInfo\":1",
	),
).is_err()
# An unknown package property is refused.
expect check(
	minimal.replace_each(
		"\"name\":\"p\"",
		"\"name\":\"p\",\"version\":\"1\"",
	),
).is_err()
# An empty checksum is refused.
expect check(
	minimal.replace_each(
		"\"checksumValue\":\"a",
		"\"checksumValue\":\"",
	),
).is_err()
# creationInfo needs a creator.
expect check(
	minimal.replace_each(
		"\"creators\":[\"Tool: t\"]",
		"\"creators\":[]",
	),
).is_err()
# An empty file list is valid.
expect check(
	minimal.replace_each("\"packages\":", "\"files\":[],\"packages\":"),
).is_ok()
# A file with a SHA-1 checksum is valid.
expect check(
	minimal.replace_each(
		"\"packages\":",
		"\"files\":[{\"SPDXID\":\"SPDXRef-f\",\"fileName\":\"./a\",\"checksums\":["
			.concat("{\"algorithm\":\"SHA1\",\"checksumValue\"")
			.concat(":\"${Str.join_with(List.repeat("b", 40), "")}\"}]}],\"packages\":"),
	).replace_each(
		"\"relatedSpdxElement\":\"SPDXRef-p\",\"relationshipType\":\"DESCRIBES\"",
		"\"relatedSpdxElement\":\"SPDXRef-f\",\"relationshipType\":\"DESCRIBES\"",
	),
).is_ok()
# A file needs a SHA-1 checksum.
expect check(
	minimal.replace_each(
		"\"packages\":",
		"\"files\":[{\"SPDXID\":\"SPDXRef-f\",\"fileName\":\"./a\",\"checksums\":[]}"
			.concat("],\"packages\":"),
	),
).is_err()
# A snippet of an undeclared file is refused.
expect check(
	minimal.replace_each(
		"\"packages\":",
		"\"snippets\":[{\"SPDXID\":\"SPDXRef-s\",\"snippetFromFile\":\"SPDXRef-missi"
			.concat("ng\",\"ranges\":[{\"startPointer\":{\"reference\":\"SPDXRef-missin")
			.concat("g\",\"offset\":1},\"endPointer\":{\"reference\":\"SPDXRef-missin")
			.concat("g\",\"offset\":2}}]}],\"packages\":"),
	),
).is_err()
# A relationship into an undeclared document is refused.
expect check(
	minimal.replace_each(
		"\"relatedSpdxElement\":\"SPDXRef-p\"",
		"\"relatedSpdxElement\":\"DocumentRef-x:SPDXRef-p\"",
	),
).is_err()
# A relationship into a declared external document is valid.
expect check(
	minimal.replace_each(
		"\"packages\":",
		"\"externalDocumentRefs\":[{\"externalDocumentId\":\"DocumentRef-x\",\"spdxD"
			.concat("ocument\":\"https://e.org/x\",\"checksum\":{\"algorithm\":\"SHA1\"")
			.concat(",\"checksumValue\":\"${Str.join_with(List.repeat("c", 40), "")}\"}")
			.concat("}],\"packages\":"),
	).replace_each(
		"\"relatedSpdxElement\":\"SPDXRef-p\"",
		"\"relatedSpdxElement\":\"DocumentRef-x:SPDXRef-p\"",
	),
).is_ok()
