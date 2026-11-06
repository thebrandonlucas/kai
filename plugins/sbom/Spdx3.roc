# SPDX 3.0.1 JSON-LD: what a document may hold, checked against the model.
#
# Ported from roc-blueprint's blueprint-core/Spdx3.roc: Copyright © 2026
# Luke Boswell and subsequent authors, under the Universal Permissive
# License (UPL), Version 1.0 (see LICENSE).
import JsonData
import Lookup
import SbomLicenses

## SPDX 3.0.1 JSON-LD serialization, checked against the published model
## (https://spdx.org/schema/3.0.1/spdx-json-schema.json and
## https://spdx.org/rdf/3.0.1/spdx-model.ttl) for the classes below.
##
## A document is one object holding exactly `@context`, the 3.0.1 context IRI,
## and `@graph`. Every `@graph` object names its class in `type` and holds only
## that class's properties, with the value kinds, cardinality and enumerations
## the schema gives them; an element has a unique IRI `spdxId` and a
## `creationInfo`.
##
## Beyond the JSON schema this applies rules the model states in prose: a
## CreationInfo's `specVersion` is the serialization's version, a license
## expression follows Annex B, a hash of a fixed-size algorithm has that many
## hex digits, a declared or concluded license relationship goes from an
## artifact to license information, and every reference resolves to an object
## in the graph of the class the property expects, or to one of the model's
## named individuals. A reference into another document needs an `import`
## ExternalMap, which this profile does not read, so such a reference is an
## error rather than an assumption.
Spdx3 := [].{
	context : Str
	context = "https://spdx.org/rdf/3.0.1/spdx-context.jsonld"

	version : Str
	version = "3.0.1"

	## One checked `@graph` object: its class, its identity (`spdxId` for an
	## element, `@id` for a CreationInfo, or "") and the object itself.
	Node : { type : Str, id : Str, tree : JsonData }

	validate : Str -> Try(List(Spdx3.Node), Str)
	validate = |text| Spdx3.check(
		JsonData.decode_with(text, JsonData.documents).map_err(JsonData.message)?,
	)

	## `validate` for a document already parsed.
	check : JsonData -> Try(List(Spdx3.Node), Str)
	check = |tree| {
		members = tree.keys()
		if members.len() != 2 or
			!members.contains("@context") or
				!members.contains("@graph") {
			return Err("an SPDX 3.0.1 document holds exactly @context and @graph")
		}
		if tree.field("@context") != Ok(JsonData.String(context)) {
			return Err("@context must be ${context}")
		}
		objects = match tree.field("@graph") {
			Ok(Array(list)) => list
			_ => return Err("@graph must be an array")
		}
		var $nodes = []
		var $entries = []
		for object in objects {
			type = match object.field("type") {
				Ok(String(name)) => name
				_ => return Err("every @graph object needs a string type")
			}
			_ = class(type)?
			id = if elements.contains(type) {
				match object.field("spdxId") {
					Ok(String(iri)) if iri_syntax(iri) => iri
					_ => return Err("${type} needs an IRI spdxId")
				}
			} else if type == "CreationInfo" {
				match object.field("@id") {
					Ok(String(node)) if iri_syntax(node) or blank_node(node) => node
					Err(_) => ""
					_ => return Err("CreationInfo @id must be a blank node or IRI")
				}
			} else {
				return Err("${type} cannot stand alone in @graph")
			}
			if !id.is_empty() {
				$entries = $entries.append({ key: id, value: type })
			}
			$nodes = $nodes.append({ type, id, tree: object })
		}
		ids = Lookup.index($entries)
		match Lookup.repeated(ids) {
			[] => {}
			[id, ..] => return Err("duplicate @graph identity ${id}")
		}
		for node in $nodes {
			check_object(node.tree, node.type, ids)?
		}
		Ok($nodes)
	}

	## The classes this profile reads and the properties of each, so a test can
	## hold them to the vendored schema (tests/sbom/schema/spdx-3.0.1.schema.json).
	classes : List({ name : Str, properties : List(Str) })
	classes = elements.concat([
		"CreationInfo",
		"Hash",
		"ExternalIdentifier",
		"DictionaryEntry",
	]).map(
		|name| {
			name,
			properties: (class(name) ?? []).map(|property| property.name),
		},
	)

	## Each enumeration this profile checks, by its definition in the schema.
	vocabularies : List({ definition : Str, values : List(Str) })
	vocabularies = [
		{
			definition: "prop_Relationship_relationshipType",
			values: relationship_types,
		},
		{ definition: "prop_Hash_algorithm", values: hash_algorithms },
		{
			definition: "prop_ElementCollection_profileConformance",
			values: profile_ids,
		},
		{ definition: "prop_Relationship_completeness", values: completeness },
		{ definition: "prop_Artifact_supportLevel", values: support_levels },
		{ definition: "prop_software_Sbom_software_sbomType", values: sbom_types },
		{
			definition: "prop_LifecycleScopedRelationship_scope",
			values: lifecycle_scopes,
		},
		{ definition: "prop_Annotation_annotationType", values: annotation_types },
		{
			definition: "prop_ExternalIdentifier_externalIdentifierType",
			values: identifier_types,
		},
		{
			definition: "prop_software_SoftwareArtifact_software_primaryPurpose",
			values: purposes,
		},
		{
			definition: "prop_software_SoftwareArtifact_software_additionalPurpose",
			values: purposes,
		},
	]

	## A `xsd:dateTimeStamp` as the schema narrows it: UTC, whole seconds, and a
	## real calendar date.
	timestamp : Str -> Bool
	timestamp = |text| {
		if text.to_utf8().len() != 20 or !text.ends_with("Z") {
			return False
		}
		parts = text.drop_suffix("Z").split_on("T")
		match parts {
			[date, time] => match (date.split_on("-"), time.split_on(":")) {
				([year, month, day], [hour, minute, second]) => {
					if year.to_utf8().len() != 4 or
						[month, day, hour, minute, second].any(|part| part.to_utf8().len() != 2) {
						return False
					}
					if ![year, month, day, hour, minute, second].all(
						|number| number.to_utf8().all(
							|byte| byte >= '0' and
								byte <= '9',
						),
					) {
						return False
					}
					y = U64.from_str(year) ?? 0
					m = U64.from_str(month) ?? 0
					d = U64.from_str(day) ?? 0
					h = U64.from_str(hour) ?? 99
					minutes = U64.from_str(minute) ?? 99
					s = U64.from_str(second) ?? 99
					leap = y % 400 == 0 or (y % 4 == 0 and y % 100 != 0)
					days = if (m == 2) (
						if (leap) 29 else 28,
					) else if ([4, 6, 9, 11].contains(m)) 30 else 31
					m >= 1 and
						m <= 12 and
							d >= 1 and
								d <= days and
									h <= 23 and
										minutes <= 59 and
											(s <= 59 or (s == 60 and h == 23 and minutes == 59))
				}
				_ => False
			}
			_ => False
		}
	}

	## Semantic Versioning 2.0.0, as `specVersion` and `licenseListVersion` use.
	semver : Str -> Bool
	semver = |text| {
		build_split = text.split_on("+")
		(core_pre, build) = match build_split {
			[a] => (a, Err(Missing))
			[a, b] => (a, Ok(b))
			_ => return False
		}
		dash = core_pre.to_utf8().find_first_index(|byte| byte == '-')
		(core, pre) = match dash {
			Ok(index) => (
				Str.from_utf8_lossy(core_pre.to_utf8().take_first(index)),
				Ok(Str.from_utf8_lossy(core_pre.to_utf8().drop_first(index + 1))),
			)
			Err(_) => (core_pre, Err(Missing))
		}
		numbers = core.split_on(".")
		if numbers.len() != 3 or !numbers.all(numeric_identifier) {
			return False
		}
		pre_ok = match pre {
			Ok(ids) => ids.split_on(".").all(
				|id| !id.is_empty() and
					identifier_chars(id) and
						(!id.to_utf8().all(|byte| byte >= '0' and byte <= '9') or
							numeric_identifier(id)),
			)
			Err(_) => True
		}
		build_ok = match build {
			Ok(ids) => ids.split_on(".").all(
				|id| !id.is_empty() and
					identifier_chars(id),
			)
			Err(_) => True
		}
		pre_ok and build_ok
	}
}

## The schema's IRI pattern `^(?!_:).+:.+`.
iri_syntax : Str -> Bool
iri_syntax = |text| {
	if text.starts_with("_:") {
		return False
	}
	bytes = text.to_utf8()
	match bytes.find_first_index(|byte| byte == ':') {
		Ok(index) => index > 0 and
			index + 1 < bytes.len() and
				!bytes.any(|byte| byte == '\n')
		Err(_) => False
	}
}

blank_node : Str -> Bool
blank_node = |text| text.starts_with("_:") and text != "_:"

## `xsd:anyURI`: a scheme, then no whitespace or control characters.
## A URI scheme character after the first: a letter, digit, `+`, `.` or `-`.
scheme_byte : U8 -> Bool
scheme_byte = |byte|
	(byte >= 'a' and byte <= 'z')
		or (byte >= 'A' and byte <= 'Z')
		or (byte >= '0' and byte <= '9')
		or byte == '+'
		or byte == '.'
		or byte == '-'

any_uri : Str -> Bool

any_uri = |text| {
	bytes = text.to_utf8()
	match bytes.find_first_index(|byte| byte == ':') {
		Ok(index) if index > 0 => {
			scheme = bytes.take_first(index)
			first = scheme.first() ?? 0
			((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z')) and
				scheme.all(scheme_byte) and

					!bytes.any(|byte| byte <= ' ' or byte == delete)
		}
		_ => False
	}
}

numeric_identifier : Str -> Bool
numeric_identifier = |text| {
	bytes = text.to_utf8()
	!bytes.is_empty() and
		bytes.all(|byte| byte >= '0' and byte <= '9') and
			(bytes.len() == 1 or bytes.first() != Ok('0'))
}

identifier_chars : Str -> Bool
identifier_chars = |text| text.to_utf8().all(
	|byte| (byte >= 'a' and byte <= 'z') or
		(byte >= 'A' and byte <= 'Z') or
			(byte >= '0' and byte <= '9') or
				byte == '-',
)

## How a property's value is written.
Kind : [
	Text,
	Date,
	Version,
	Uri,
	Purl,
	MediaType,
	Enum(List(Str)),
	Ref(List(Str), List(Str)),
	Creation,
	Inline(Str),
]

## `Many(min)` properties are JSON arrays with at least `min` items.
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

agents = ["Agent", "Organization", "Person", "SoftwareAgent"]

licenses = ["simplelicensing_LicenseExpression"]

license_individuals = [
	"expandedlicensing_NoAssertionLicense",
	"expandedlicensing_NoneLicense",
]

element_individuals = [
	"NoAssertionElement",
	"NoneElement",
	"SpdxOrganization",
].concat(license_individuals)

artifacts = ["software_Package", "software_File"]

elements = agents.concat([
	"Tool",
	"SpdxDocument",
	"software_Sbom",
	"Relationship",
	"LifecycleScopedRelationship",
	"Annotation",
]).concat(artifacts).concat(licenses)

any_element : Kind
any_element = Ref(elements, element_individuals)

purposes = [
	"application",
	"archive",
	"bom",
	"configuration",
	"container",
	"data",
	"device",
	"deviceDriver",
	"diskImage",
	"documentation",
	"evidence",
	"executable",
	"file",
	"filesystemImage",
	"firmware",
	"framework",
	"install",
	"library",
	"manifest",
	"model",
	"module",
	"operatingSystem",
	"other",
	"patch",
	"platform",
	"requirement",
	"source",
	"specification",
	"test",
]

relationship_types = [
	"affects",
	"amendedBy",
	"ancestorOf",
	"availableFrom",
	"configures",
	"contains",
	"coordinatedBy",
	"copiedTo",
	"delegatedTo",
	"dependsOn",
	"descendantOf",
	"describes",
	"doesNotAffect",
	"expandsTo",
	"exploitCreatedBy",
	"fixedBy",
	"fixedIn",
	"foundBy",
	"generates",
	"hasAddedFile",
	"hasAssessmentFor",
	"hasAssociatedVulnerability",
	"hasConcludedLicense",
	"hasDataFile",
	"hasDeclaredLicense",
	"hasDeletedFile",
	"hasDependencyManifest",
	"hasDistributionArtifact",
	"hasDocumentation",
	"hasDynamicLink",
	"hasEvidence",
	"hasExample",
	"hasHost",
	"hasInput",
	"hasMetadata",
	"hasOptionalComponent",
	"hasOptionalDependency",
	"hasOutput",
	"hasPrerequisite",
	"hasProvidedDependency",
	"hasRequirement",
	"hasSpecification",
	"hasStaticLink",
	"hasTest",
	"hasTestCase",
	"hasVariant",
	"invokedBy",
	"modifiedBy",
	"other",
	"packagedBy",
	"patchedBy",
	"publishedBy",
	"reportedBy",
	"republishedBy",
	"serializedInArtifact",
	"testedOn",
	"trainedOn",
	"underInvestigationFor",
	"usesTool",
]

profile_ids = [
	"ai",
	"build",
	"core",
	"dataset",
	"expandedLicensing",
	"extension",
	"lite",
	"security",
	"simpleLicensing",
	"software",
]

completeness = ["complete", "incomplete", "noAssertion"]

support_levels = [
	"deployed",
	"development",
	"endOfSupport",
	"limitedSupport",
	"noAssertion",
	"noSupport",
	"support",
]

sbom_types = ["analyzed", "build", "deployed", "design", "runtime", "source"]

lifecycle_scopes = [
	"build",
	"design",
	"development",
	"other",
	"runtime",
	"test",
]

annotation_types = ["other", "review"]

identifier_types = [
	"cpe22",
	"cpe23",
	"cve",
	"email",
	"gitoid",
	"other",
	"packageUrl",
	"securityOther",
	"swhid",
	"swid",
	"urlScheme",
]

hash_algorithms = [
	"adler32",
	"blake2b256",
	"blake2b384",
	"blake2b512",
	"blake3",
	"crystalsDilithium",
	"crystalsKyber",
	"falcon",
	"md2",
	"md4",
	"md5",
	"md6",
	"other",
	"sha1",
	"sha224",
	"sha256",
	"sha384",
	"sha3_224",
	"sha3_256",
	"sha3_384",
	"sha3_512",
	"sha512",
]

element_props : List(Property)
element_props = [
	one("comment", Text),
	needs(one("creationInfo", Creation)),
	one("description", Text),
	many("externalIdentifier", Inline("ExternalIdentifier")),
	one("name", Text),
	one("summary", Text),
	many("verifiedUsing", Inline("Hash")),
]

collection_props : List(Property)
collection_props = element_props.concat([
	many("element", any_element),
	many("profileConformance", Enum(profile_ids)),
	many("rootElement", any_element),
])

relationship_props : List(Property)
relationship_props = element_props.concat([
	one("completeness", Enum(completeness)),
	one("endTime", Date),
	needs(one("from", any_element)),
	needs(one("relationshipType", Enum(relationship_types))),
	one("startTime", Date),
	needs({ ..many("to", any_element), count: Many(1) }),
])

artifact_props : List(Property)
artifact_props = element_props.concat([
	one("builtTime", Date),
	many("originatedBy", Ref(agents, ["SpdxOrganization"])),
	one("releaseTime", Date),
	many("standardName", Text),
	one("suppliedBy", Ref(agents, ["SpdxOrganization"])),
	many("supportLevel", Enum(support_levels)),
	one("validUntilTime", Date),
	many("software_additionalPurpose", Enum(purposes)),
	many("software_attributionText", Text),
	one("software_copyrightText", Text),
	one("software_primaryPurpose", Enum(purposes)),
])

package_props : List(Property)
package_props = artifact_props.concat([
	one("software_downloadLocation", Uri),
	one("software_homePage", Uri),
	one("software_packageUrl", Purl),
	one("software_packageVersion", Text),
	one("software_sourceInfo", Text),
])

## The properties of each class this profile reads, from the 3.0.1 schema.
class : Str -> Try(List(Property), Str)
class = |name|
	match name {
		"CreationInfo" => Ok([
			one("comment", Text),
			needs(one("created", Date)),
			needs({
				..many("createdBy", Ref(agents, ["SpdxOrganization"])),
				count: Many(1),
			}),
			many("createdUsing", Ref(["Tool"], [])),
			needs(one("specVersion", Version)),
		])
		"Agent" | "Organization" | "Person" | "SoftwareAgent" | "Tool" =>
			Ok(element_props)
		"SpdxDocument" => Ok(
			collection_props.append(
				one(
					"dataLicense",
					Ref(licenses, license_individuals),
				),
			),
		)
		"software_Sbom" => Ok(
			collection_props.append(
				many(
					"software_sbomType",
					Enum(sbom_types),
				),
			),
		)
		"software_Package" => Ok(package_props)
		"software_File" => Ok(
			artifact_props.concat([
				one("contentType", MediaType),
				one("software_fileKind", Enum(["directory", "file"])),
			]),
		)
		"Relationship" => Ok(relationship_props)
		"LifecycleScopedRelationship" => Ok(
			relationship_props.append(
				one(
					"scope",
					Enum(lifecycle_scopes),
				),
			),
		)
		"simplelicensing_LicenseExpression" => Ok(
			element_props.concat([
				many("simplelicensing_customIdToUri", Inline("DictionaryEntry")),
				needs(one("simplelicensing_licenseExpression", Text)),
				one("simplelicensing_licenseListVersion", Version),
			]),
		)
		"Annotation" => Ok(
			element_props.concat([
				needs(one("annotationType", Enum(annotation_types))),
				one("contentType", MediaType),
				one("statement", Text),
				needs(one("subject", any_element)),
			]),
		)
		"Hash" => Ok([
			one("comment", Text),
			needs(one("algorithm", Enum(hash_algorithms))),
			needs(one("hashValue", Text)),
		])
		"ExternalIdentifier" => Ok([
			one("comment", Text),
			needs(one("externalIdentifierType", Enum(identifier_types))),
			needs(one("identifier", Text)),
			many("identifierLocator", Uri),
			one("issuingAuthority", Text),
		])
		"DictionaryEntry" => Ok([needs(one("key", Text)), one("value", Text)])
		_ => Err("SPDX 3.0.1 class ${name} is outside this profile")
	}

Ids : List(Lookup.Entry(Str))

check_object : JsonData, Str, Ids -> Try({}, Str)
check_object = |tree, type, ids| {
	properties = class(type)?
	identity = if (
		(
			elements.contains(type),
		)
	) "spdxId" else if (type == "CreationInfo") "@id" else ""
	for key in tree.keys() {
		if key != "type" and
			key != identity and
				!properties.any(|property| property.name == key) {
			return Err("${type} has no property ${key} in this profile")
		}
	}
	for property in properties {
		match tree.field(property.name) {
			Err(_) => if property.required {
				return Err("${type} requires ${property.name}")
			}
			Ok(value) => match (property.count, value) {
				(
					One,
					_,
				) => check_value(
					value,
					property.kind,
					ids,
				).map_err(|problem| "${type}.${property.name}: ${problem}")?
				(Many(min), Array(values)) => {
					if values.len() < min {
						return Err(
							"${type}.${property.name} needs at least ${min.to_str()} "
								.concat("values"),
						)
					}
					for item in values {
						check_value(
							item,
							property.kind,
							ids,
						).map_err(|problem| "${type}.${property.name}: ${problem}")?
					}
				}
				(Many(_), _) => return Err("${type}.${property.name} must be an array")
			}
		}
	}
	model_rules(tree, type, ids)
}

check_value : JsonData, Kind, Ids -> Try({}, Str)
check_value = |value, kind, ids|
	match (kind, value) {
		(Text, String(_)) => Ok({})
		(
			Date,
			String(text),
		) => if (Spdx3.timestamp(text)) Ok({}) else Err("not a UTC dateTimeStamp")
		(
			Version,
			String(text),
		) => if (Spdx3.semver(text)) Ok({}) else Err("not a semantic version")
		(Uri, String(text)) => if (any_uri(text)) Ok({}) else Err("not a URI")
		(Purl, String(text)) => if (text.starts_with("pkg:") and
			any_uri(text)) Ok({}) else Err("not a package URL")
		(MediaType, String(text)) => match text.split_on("/") {
			[kind_name, sub] if !kind_name.is_empty() and !sub.is_empty() => Ok({})
			_ => Err("not a media type")
		}
		(
			Enum(allowed),
			String(text),
		) => if (
			(
				allowed.contains(text),
			)
		) Ok({}) else Err("${text} is not a permitted value")
		(Ref(classes, individuals), String(text)) => {
			if individuals.contains(text) {
				return Ok({})
			}
			match Lookup.find(ids, text) {
				Ok(found) if classes.contains(found) => Ok({})
				Ok(found) => Err(
					"${text} is a ${found}, not a "
						.concat("${Str.join_with(classes, " or ")}"),
				)
				Err(_) => Err("${text} does not resolve within the document")
			}
		}
		(
			Creation,
			String(text),
		) => if (
			(
				Lookup.find(ids, text) == Ok("CreationInfo"),
			)
		) Ok({}) else Err("${text} is not a CreationInfo in the document")
		(
			Creation,
			Object(_),
		) => if (
			(
				value.field("type") == Ok(JsonData.String("CreationInfo")),
			)
		) check_object(
			value,
			"CreationInfo",
			ids,
		) else Err("inline creationInfo must be a CreationInfo")
		(
			Inline(name),
			Object(_),
		) => if (value.field("type") == Ok(JsonData.String(name))) check_object(
			value,
			name,
			ids,
		) else Err("expected an inline ${name}")
		_ => Err("wrong JSON kind")
	}

hex_length : Str -> Try(U64, [Unfixed])
hex_length = |algorithm|
	match algorithm {
		"md2" | "md4" | "md5" => Ok(32)
		"sha1" => Ok(40)
		"sha224" | "sha3_224" => Ok(56)
		"sha256" | "sha3_256" | "blake2b256" | "blake3" => Ok(64)
		"sha384" | "sha3_384" | "blake2b384" => Ok(96)
		"sha512" | "sha3_512" | "blake2b512" => Ok(128)
		"adler32" => Ok(8)
		_ => Err(Unfixed)
	}

model_rules : JsonData, Str, Ids -> Try({}, Str)
model_rules = |tree, type, ids|
	match type {
		"CreationInfo" => if (
			(
				tree.field("specVersion") == Ok(JsonData.String(Spdx3.version)),
			)
		) Ok(
			{},
		) else Err(
			"CreationInfo.specVersion must be ${Spdx3.version} under the "
				.concat("${Spdx3.version} context"),
		)
		"Hash" => {
			algorithm = (tree.field("algorithm") ?? JsonData.Null).string() ?? ""
			hash = (tree.field("hashValue") ?? JsonData.Null).string() ?? ""
			match hex_length(algorithm) {
				Ok(len) => if (
					hash.to_utf8().len() == len and
						hash.to_utf8().all(
							|byte| (byte >= '0' and byte <= '9') or
								(byte >= 'a' and byte <= 'f') or
									(byte >= 'A' and byte <= 'F'),
						)
				) Ok(
					{},
				) else Err("Hash ${algorithm} value is not ${len.to_str()} hex digits")
				Err(Unfixed) => if (hash.is_empty()) Err("empty Hash value") else Ok({})
			}
		}
		"simplelicensing_LicenseExpression" => {
			expression = (
				tree.field("simplelicensing_licenseExpression") ?? JsonData.Null,
			).string() ?? ""
			if !SbomLicenses.expression(expression) {
				return Err("invalid license expression ${Json.to_str(expression)}")
			}
			entries = (
				tree.field("simplelicensing_customIdToUri") ?? JsonData.Array([]),
			).array() ?? []
			keys = entries.map(
				|entry| (entry.field("key") ?? JsonData.Null).string() ?? "",
			)
			for entry in entries {
				key = (entry.field("key") ?? JsonData.Null).string() ?? ""
				uri = (entry.field("value") ?? JsonData.Null).string() ?? ""
				if !key.starts_with("LicenseRef-") or !any_uri(uri) {
					return Err("customIdToUri maps a LicenseRef- identifier to a URI")
				}
			}
			if keys.len() != keys.fold(
				[],
				|all, key| if (all.contains(key)) all else all.append(key),
			).len() {
				return Err("duplicate customIdToUri key")
			}
			Ok({})
		}
		"Relationship" | "LifecycleScopedRelationship" => {
			relationship = (
				tree.field("relationshipType") ?? JsonData.Null,
			).string() ?? ""
			if relationship == "hasDeclaredLicense" or
				relationship == "hasConcludedLicense" {
				from = (tree.field("from") ?? JsonData.Null).string() ?? ""
				destinations = (
					(tree.field("to") ?? JsonData.Array([])).array() ?? [],
				).map(|target| target.string() ?? "")
				if !artifacts.contains(Lookup.find(ids, from) ?? "") {
					return Err("${relationship} must go from an artifact")
				}
				if destinations.any(
					|target| !license_individuals.contains(target) and !licenses.contains(
						Lookup.find(
							ids,
							target,
						) ?? "",
					),
				) {
					return Err("${relationship} must go to license information")
				}
			}
			Ok({})
		}
		_ => Ok({})
	}

minimal : Str
minimal = "{\"@context\":\"${Spdx3.context}\",\"@graph\":[{\"type\":\"Creation"
	.concat("Info\",\"@id\":\"_:c\",\"specVersion\":\"3.0.1\",\"created\":\"2026-")
	.concat("10-21T00:00:00Z\",\"createdBy\":[\"https://e.org/d#a\"]},{\"type\"")
	.concat(":\"Organization\",\"spdxId\":\"https://e.org/d#a\",\"creationInfo\"")
	.concat(":\"_:c\",\"name\":\"A\"},{\"type\":\"software_Package\",\"spdxId\"")
	.concat(":\"https://e.org/d#p\",\"creationInfo\":\"_:c\",\"name\":\"p\",\"ver")
	.concat("ifiedUsing\":[{\"type\":\"Hash\",\"algorithm\":\"sha256\",\"hashValu")
	.concat("e\":\"${Str.join_with(List.repeat("a", 64), "")}\"}]},{\"type\":\"si")
	.concat("mplelicensing_LicenseExpression\",\"spdxId\":\"https://e.org/d#l\"")
	.concat(",\"creationInfo\":\"_:c\",\"simplelicensing_licenseExpression\":\"MI")
	.concat("T\"},{\"type\":\"Relationship\",\"spdxId\":\"https://e.org/d#r\",\"c")
	.concat("reationInfo\":\"_:c\",\"from\":\"https://e.org/d#p\",\"relationshipT")
	.concat("ype\":\"hasDeclaredLicense\",\"to\":[\"https://e.org/d#l\"]}]}")

# The minimal SPDX 3.0.1 document is valid.
expect Spdx3.validate(minimal).is_ok()
# Another SPDX context is refused.
expect Spdx3.validate(
	minimal.replace_each(
		"3.0.1/spdx-context",
		"3.0.0/spdx-context",
	),
).is_err()
# CreationInfo must name spec version 3.0.1.
expect Spdx3.validate(
	minimal.replace_each(
		"\"specVersion\":\"3.0.1\"",
		"\"specVersion\":\"3.0\"",
	),
).is_err()
# A property of SPDX 2, versionInfo, is refused.
expect Spdx3.validate(
	minimal.replace_each(
		"\"name\":\"p\"",
		"\"name\":\"p\",\"versionInfo\":\"1\"",
	),
).is_err()
# A relationship to nothing is refused.
expect Spdx3.validate(
	minimal.replace_each(
		"\"to\":[\"https://e.org/d#l\"]",
		"\"to\":[]",
	),
).is_err()
# A relationship to an undeclared element is refused.
expect Spdx3.validate(
	minimal.replace_each(
		"\"to\":[\"https://e.org/d#l\"]",
		"\"to\":[\"https://e.org/d#missing\"]",
	),
).is_err()
# A license relationship to an agent is refused.
expect Spdx3.validate(
	minimal.replace_each(
		"\"to\":[\"https://e.org/d#l\"]",
		"\"to\":[\"https://e.org/d#a\"]",
	),
).is_err()
# An individual license from the SPDX vocabulary is accepted.
expect Spdx3.validate(
	minimal.replace_each(
		"\"to\":[\"https://e.org/d#l\"]",
		"\"to\":[\"expandedlicensing_NoAssertionLicense\"]",
	),
).is_ok()
# An empty hash value is refused.
expect Spdx3.validate(
	minimal.replace_each(
		"\"hashValue\":\"a",
		"\"hashValue\":\"",
	),
).is_err()
# A malformed license expression is refused.
expect Spdx3.validate(minimal.replace_each("\"MIT\"", "\"MIT OR\"")).is_err()
# createdBy must be a list.
expect Spdx3.validate(
	minimal.replace_each(
		"\"createdBy\":[\"https://e.org/d#a\"]",
		"\"createdBy\":\"https://e.org/d#a\"",
	),
).is_err()
# An impossible date is refused.
expect Spdx3.validate(minimal.replace_each("2026-10-21T00", "2026-02-30T00"))
	.is_err()
# Two elements with one identifier are refused.
expect Spdx3.validate(
	minimal.replace_each(
		"\"spdxId\":\"https://e.org/d#r\"",
		"\"spdxId\":\"https://e.org/d#p\"",
	),
).is_err()
# A blank node cannot identify an element.
expect Spdx3.validate(
	minimal.replace_each(
		"\"spdxId\":\"https://e.org/d#r\"",
		"\"spdxId\":\"_:r\"",
	),
).is_err()
# Semantic versions follow semver 2.0.0.
expect Spdx3.semver("3.26.0") and
	Spdx3.semver("1.0.0-rc.1+build.5") and
		!Spdx3.semver("3.26") and
			!Spdx3.semver("01.0.0") and
				!Spdx3.semver("1.0.0-01")

## The ASCII delete character, which no URI or name may hold.
delete : U8
delete = 127
