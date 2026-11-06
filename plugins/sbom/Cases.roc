# roc-blueprint's own SBOM profile cases (tests/blueprint, from its
# tests/sbom/fixtures, UPL-1.0): inspect writes the inventories its
# blueprint-sbom wrote, byte for byte, from the same compositions and
# inputs, the renderings are the documents it wrote, and each tampered
# composition is refused with its message.
import Lookup
import Profile

import "tests/blueprint/input-composition.json" as input_composition : Str
import "tests/blueprint/input-inventory.json" as input_inventory : Str
import "tests/blueprint/input-subject.json" as input_subject : Str
import "tests/blueprint/input-context.json" as input_context : Str
import "tests/blueprint/native-linux.spdx.json" as linux_spdx : Str
import "tests/blueprint/native-linux.spdx-2.3.json" as linux_spdx2 : Str
import "tests/blueprint/native-linux.cdx.json" as linux_cdx : Str
import "tests/blueprint/import-composition.json" as import_composition : Str
import "tests/blueprint/import-subject.json" as import_subject : Str
import "tests/blueprint/import-context.json" as import_context : Str
import "tests/blueprint/import-source.json" as import_source : Str
import "tests/blueprint/import-x86_64-linux.json" as import_x86 : Str
import "tests/blueprint/import-aarch64-linux.json" as import_arm : Str
import "tests/blueprint/native-source-import.spdx.json" as import_spdx : Str
import "tests/blueprint/native-source-import.spdx-2.3.json" as spdx2 : Str
import "tests/blueprint/native-source-import.cdx.json" as import_cdx : Str

Cases := [].{

	## The systems the cases declare.
	systems : List(Str)
	systems = ["x86_64-linux", "aarch64-linux"]

	## The source-import case's inputs: its one file source, `dep`, pinned
	## by the SHA-256 the supplier publishes.
	source_import : Profile.Inputs
	source_import = {
		..Profile.no_inputs,
		systems: Cases.systems,
		sources: [
			{
				name: "dep",
				provider: "file",
				ref: "https://example.org/releases/1.2.0/dep-abc.tar.zst",
				rev: "",
				digest: "sha256:${dep_sha256}",
			},
		],
	}

	## The SHA-256 of a text, in hex.
	digest : Str -> Str
	digest = |text| Crypto.SHA256.hash(text.to_utf8()).to_hex()

	parse_composition : Str -> Try(Profile.Composition, Str)
	parse_composition = |text| {
		parsed : Try(Profile.Composition, _)
		parsed = Json.parse(Profile.normalize_input(text)?)
		parsed.map_err(|_| "not a composition")
	}

	parse_inventory : Str -> Try(Profile.Inventory, Str)
	parse_inventory = |text| {
		parsed : Try(Profile.Inventory, _)
		parsed = Json.parse(Profile.normalize_input(text)?)
		parsed.map_err(|_| "not an inventory")
	}

	parse_subject : Str -> Try(Profile.Subject, Str)
	parse_subject = |text| {
		parsed : Try(Profile.Subject, _)
		parsed = Json.parse(Profile.normalize_input(text)?)
		parsed.map_err(|_| "not a subject")
	}

	parse_context : Str -> Try(Profile.Context, Str)
	parse_context = |text| {
		parsed : Try(Profile.Context, _)
		parsed = Json.parse(text)
		parsed.map_err(|_| "not a context")
	}

	## The inventory text inspect writes.
	inventory_text : Profile.Inputs, Str, Str -> Try(Str, Str)
	inventory_text = |inputs, target, composition| {
		parsed = Cases.parse_composition(composition)?
		inventory = Profile.inspect(inputs, target, parsed)?
		Ok("${Json.to_str(inventory)}\n")
	}

	## Each rendering of an inventory, in the order SPDX 3.0.1, SPDX 2.3 and
	## CycloneDX 1.7.
	renderings : Str, Str, Str -> Try(List(Str), Str)
	renderings = |inventory, subject, context| {
		i = Cases.parse_inventory(inventory)?
		s = Cases.parse_subject(subject)?
		c = Cases.parse_context(context)?
		Ok([
			Profile.render(i, s, c)?,
			Profile.render_spdx2(i, s, c)?,
			Profile.render_cyclonedx(i, s, c)?,
		])
	}
}

systems = Cases.systems

## The SHA-256 the supplier of `dep` publishes for it.
dep_sha256 = "3945bb64314f2f25732bb36f3bc7f52a2087cfde17439086cf3acd785e3fdfca"

source_import = Cases.source_import

inventory_text = Cases.inventory_text

renderings = Cases.renderings

parse_composition = Cases.parse_composition

# The reference native case: inspect writes roc-blueprint's inventory byte
# for byte from the same composition, and bind its three renderings.
expect {
	inputs = { ..Profile.no_inputs, systems }
	inventory_text(
		inputs,
		"x86_64-linux",
		input_composition,
	) == Ok(input_inventory)
		and renderings(input_inventory, input_subject, input_context)
			== Ok([linux_spdx, linux_spdx2, linux_cdx])
}

# A FetchAll is Blueprint's SourceFile: the supplier's source SBOM imports
# into each consumer target with the inventories roc-blueprint committed,
# and the x86_64-linux one renders as its native-source-import case.
expect {
	inputs = source_import
	[
		("source", import_source),
		("x86_64-linux", import_x86),
		("aarch64-linux", import_arm),
	]
		.all(
			|(target, expected)| inventory_text(
				inputs,
				target,
				import_composition,
			) == Ok(expected),
		)
		and renderings(import_x86, import_subject, import_context)
			== Ok([import_spdx, spdx2, import_cdx])
}

# The refusals roc-blueprint's source-import case lists, each for the
# tampered composition its expected.json describes.
expect {
	inputs = source_import
	c = parse_composition(import_composition)?
	first = c.imported_documents.first()?
	documents = |entry| { ..c, imported_documents: [entry] }
	dep = |target| c.components.map(|x| if (x.id == "dep") { ..x, target } else x)
	refusal = |tampered| Profile.inspect(inputs, "x86_64-linux", tampered)
	a64 = Str.join_with(List.repeat("a", 64), "")
	refusal(
		documents({ ..first, sha256: a64 }),
	) == Err("imported SBOM content digest mismatch")
		and refusal(documents({ ..first, subject: { ..first.subject, sha256: a64 } }))
			== Err("import subject filename/version/SHA256 mismatch")
		and refusal(
			documents({
				..first,
				subject: { ..first.subject, version: "1.2.1" },
			}),
		)
			== Err("import subject filename/version/SHA256 mismatch")
		and refusal(documents({ ..first, target: "x86_64-linux" }))
			== Err("imported document subject target mismatch")
		and refusal({ ..c, components: dep("x86_64-linux") })
			== Err("imported subject conflicts with authoritative component artifact")
		and refusal(documents({ ..first, target: "aarch64-linux" }))
			== Err("import target differs from subject")
}
