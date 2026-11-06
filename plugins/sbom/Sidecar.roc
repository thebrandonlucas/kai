# Checks of a written SBOM sidecar against the profile and its inventory.
#
# Ported from roc-blueprint's blueprint-core/Sidecar.roc: Copyright © 2026
# Luke Boswell and subsequent authors, under the Universal Permissive
# License (UPL), Version 1.0 (see LICENSE).
import Lookup
import Profile

## Checks of a written SBOM sidecar, SPDX 3.0.1, SPDX 2.3 or CycloneDX 1.7,
## that anyone can run on what they received or are about to publish. `check`
## holds a document to the blueprint profile beyond its format's model: one
## described subject with its final digest, a connected graph, nothing the
## format could not carry, and evidence that accounts for every inspected
## input. `against_inventory` compares it with the inventory it was bound
## from, and `same_graph` compares two renderings of one document.
Sidecar := [].{
	Evidence : {
		profile : Str,
		revision : Str,
		target : Str,
		coverage : List(Profile.Coverage),
		inspected : List(Str),
		dispositions : List(Profile.Disposition),
	}

	Checked : {
		document : Profile.Document,
		evidence : Sidecar.Evidence,
		subject : Profile.Package,
	}

	check : Str -> Try(Sidecar.Checked, Str)
	check = |text| {
		document = if text.contains("\"bomFormat\"") {
			Profile.read_cyclonedx(text)?
		} else {
			Profile.read(text)?
		}
		ids = document.packages_.map(|entry| entry.id)
		if !document.gaps.is_empty() {
			return Err(
				"a Blueprint sidecar states only what its format can carry, but "
					.concat("this one has ${Str.join_with(document.gaps, "; ")}"),
			)
		}
		if document.roots != ["Subject"] {
			return Err("the document must describe exactly its delivered subject")
		}
		subject = document.packages_
			.find_first(|entry| entry.id == "Subject")
			.map_err(|_| "missing delivered subject")?
		if subject.name.is_empty() or
			subject.name.contains("/") or
				subject.name.contains("\\") or
					subject.version.is_empty() or
						!lowercase_sha256(subject.sha256) {
			return Err(
				"the subject needs a file name, a version and a lowercase SHA-256",
			)
		}
		subject_meta : Try({ target : Str, digest_kind : Str }, _)
		subject_meta = Json.parse(subject.comment)
		meta = subject_meta.map_err(
			|_| "the subject comment does not name its target",
		)?
		if meta.target.is_empty() or meta.digest_kind != "final-deliverable-sha256" {
			return Err("the subject digest must be the final deliverable's")
		}
		keys = document.relationships
			.map(|edge| "${edge.from} ${edge.relation} ${edge.scope} ${edge.to}")
		if keys.len() != unique(keys).len() {
			return Err("duplicate relationship")
		}
		var $reached = ["Subject"]
		var $changed = True
		while $changed {
			$changed = False
			for edge in document.relationships {
				if $reached.contains(edge.from) and !$reached.contains(edge.to) {
					$reached = $reached.append(edge.to)
					$changed = True
				}
				if $reached.contains(edge.to) and !$reached.contains(edge.from) {
					$reached = $reached.append(edge.from)
					$changed = True
				}
			}
		}
		if ids.any(|id| !$reached.contains(id)) {
			return Err("disconnected component")
		}
		evidence = match document.evidence {
			[only] => {
				decoded : Try(Sidecar.Evidence, _)
				decoded = Json.parse(Profile.normalize_input(only)?)
				decoded.map_err(|_| "the evidence annotation is not profile evidence")?
			}
			_ => return Err("expected exactly one evidence annotation")
		}
		if evidence.profile != Profile.profile {
			return Err(
				"evidence names profile ${evidence.profile}, not "
					.concat("${Profile.profile}"),
			)
		}
		if evidence.target != meta.target {
			return Err("evidence target differs from the subject's")
		}
		if !document.namespace.ends_with("revision-${evidence.revision}") {
			return Err("namespace does not end with its evidence revision")
		}
		if evidence.coverage.is_empty() {
			return Err("unknown coverage silently omitted")
		}
		_ = Profile.validate_coverage(evidence.coverage, ids, document.relationships)?

		inputs = evidence.dispositions.map(|entry| entry.input)
		if unique(evidence.inspected).len() != evidence.inspected.len() or
			unique(inputs).len() != inputs.len() or
				sorted(evidence.inspected) != sorted(inputs) {
			return Err("unexplained known-input omission")
		}
		if evidence.dispositions.any(
			|entry| entry.reason.is_empty() or
				(!entry.component.is_empty() and !ids.contains(entry.component)),
		) {
			return Err("input disposition without a reason or with an unknown component")
		}
		for entry in document.packages_ {
			Profile.validate_metadata(entry)?
			if entry.version.is_empty() or
				entry.license.is_empty() or
					(entry.supplier != "NOASSERTION" and
						!entry.supplier.starts_with("Person: ") and
							!entry.supplier.starts_with("Organization: ")) {
				return Err(
					"package ${entry.id} needs a version, a license and an SPDX "
						.concat("supplier"),
				)
			}
			if entry.id != "Subject" {
				identity : Try({ identity : Str, origin : Str, target : Str }, _)
				identity = Json.parse(entry.comment)
				match identity {
					Ok(found) => if found.identity.is_empty() or
						found.origin.is_empty() or
							!Profile.admits_target(
								evidence.target,
								found.target,
							) {
						return Err(
							"package ${entry.id} lacks its identity or names another "
								.concat("target"),
						)
					}
					Err(_) => return Err("package ${entry.id} does not record its identity")
				}
			}
		}
		if [
			"/Users/",
			"/home/",
			"/private/",
			"/tmp/",
			"/nix/store/",
			"github_pat_",
			"ghp_",
			"BEGIN PRIVATE KEY",
		].any(|marker| text.contains(marker)) {
			return Err("the document holds a developer path or credential")
		}
		Ok({ document, evidence, subject })
	}

	## The inventory a sidecar was bound from is what its evidence states.
	against_inventory : Sidecar.Checked, Profile.Inventory -> Try({}, Str)
	against_inventory = |checked, inventory|
		if inventory.target != checked.evidence.target or
			inventory.inspected != checked.evidence.inspected or
				inventory.inputs != checked.evidence.dispositions or
					inventory.coverage != checked.evidence.coverage {
			Err("evidence differs from the inventory")
		} else if sorted(
			inventory.components
				.map(|entry| entry.id),
		) != sorted(
			checked
				.document
				.packages_
				.map(|entry| entry.id)
				.drop_if(|id| id == "Subject"),
		) {
			Err("known component omission")
		} else if inventory.components
			.any(
				|component| checked.document
					.packages_
					.find_first(
						|entry| entry.id == component
							.id,
					) != Ok(
					Profile.package_of(component),
				),
			) {
			Err("component metadata differs from the inventory")
		} else if inventory.relationships
			.sort_with(compare_edges) != checked
			.document
			.relationships
			.sort_with(compare_edges) {
			Err("relationships differ from the inventory")
		} else {
			Ok({})
		}

	## Two renderings of one subject state the same package graph.
	same_graph : Sidecar.Checked, Sidecar.Checked -> Bool
	same_graph = |a, b| { ..a.document, version: "" } == {
		..b.document,
		version: "",
	}

}

unique : List(Str) -> List(Str)
unique = |values| values.fold(
	[],
	|all, value| if (all.contains(value)) all else all.append(value),
)

sorted : List(Str) -> List(Str)
sorted = |values| values.sort_with(Lookup.bytewise)

lowercase_sha256 : Str -> Bool
lowercase_sha256 = |value| value.to_utf8().len() == 64 and
	value.to_utf8().all(
		|byte| (byte >= '0' and byte <= '9') or
			(byte >= 'a' and byte <= 'f'),
	)

compare_edges : Profile.Edge, Profile.Edge -> [Before, Same, After]
compare_edges = |a, b| Lookup.bytewise(Json.to_str(a), Json.to_str(b))
