# weaver 0.10.1's release on Kai (tests/weaver): its reviewed composition,
# the supplier SBOMs it imports, its bundle's members, and the lock of its
# Kaifile on Kai. kai sbom names the inputs the composition disposes of and
# writes the inventory, sidecars and manifest weaver published, byte for
# byte, and with kai-sbom as the generator differs from them only in its
# name. The blueprint cases' inputs come from the same settings on Kai.
import pf.Implementation
import pf.Layout
import pf.Plan
import std.Config
import std.StdModel
import Cases
import Inputs
import Lookup
import Profile
import Sbom

import "tests/weaver/package.json" as weaver_package : Str
import "tests/weaver/imports.json" as weaver_imports : Str
import "tests/weaver/members.json" as weaver_members : Str
import "tests/weaver/lock.json" as weaver_lock : Str

Release := [].{

	## weaver's Kaifile on Kai: Blueprint.roc's SourceFiles as FetchAll, its
	## Programs as FetchLocked downloads, its RocPackages, environments and
	## tasks, as weaver's port declares them.
	weaver : List(Config.Setting)
	weaver = {
		automation = "https://github.com/lukewilliamboswell/roc-automation/releases/"
			.concat("download/tools-0.9.0")
		file = |url|
			systems.map(
				|system| {
					system,
					url: "${url}-${system.to_str()}",
					mirrors: [],
					program: File,
				},
			)
		nightly = |system, build| {
			tag = "nightly-2026-10-23-18478ff"
			top = "roc_nightly-${build}-${tag.drop_prefix("nightly-")}"
			{
				system,
				url: "${gh}/roc-lang/nightlies/releases/download/${tag}/${top}.tar.gz",
				mirrors: [],
				program: Archive("${top}/roc"),
			}
		}
		[
			Name("weaver"),
			Systems(systems),
			FetchAll(
				"roc-ansi",
				{
					url: "${ansi}/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
					sha256: "93750a9b9993e4e2996feac0ddd6f199b6f3fd9ba81154a74f09f47481e1e2ba",
				},
			),
			FetchAll(
				"path",
				{
					url: "${path_rel}/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
					sha256: "435499c7ffb4f357d2956e3bb2802a81264f6f2f50c896c9913fb86f7bc752bb",
				},
			),
			FetchLocked(
				"roc-stable",
				[
					nightly("x86_64-linux", "linux_x86_64"),
					nightly("aarch64-linux", "linux_arm64"),
					nightly("aarch64-darwin", "macos_apple_silicon"),
				],
			),
			FetchLocked("roc-docs", file("${automation}/roc-docs")),
			FetchLocked(
				"blueprint-sbom",
				file(
					"https://github.com/lukewilliamboswell/roc-blueprint/releases/downloa"
						.concat("d/0.11.0/blueprint-sbom"),
				),
			),
			FetchLocked("release-package", file("${automation}/release-package")),
			Environment(
				"dev",
				[
					Tools(["roc-stable#roc-stable"]),
					RocPackages([
						"https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZ"
							.concat("wR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst"),
						"https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9M"
							.concat("o6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst"),
					]),
					Expect(["gh", "git", "gzip", "roc", "sh", "shasum", "tar", "unzip"]),
				],
			),
			Environment(
				"docs",
				[Tools(["roc-docs#roc-docs"]), Expect(["realpath", "sh"])],
			),
			Environment("sbom", [Tools(["blueprint-sbom#blueprint-sbom"])]),
			Environment(
				"release",
				[
					Tools(["release-package#release-package"]),
					Expect(
						["roc", "git", "gh", "tar", "unzip", "zip", "chmod", "touch", "env"],
					),
				],
			),
			Shell("default", [Use("dev")]),
			Task("check", [Use("dev"), Run(["scripts/check_all.roc"])]),
			Task("release-package", [Use("release"), Run(["release-package"])]),
			Task("prepare-sbom", [Use("dev"), Run(["scripts/prepare_sbom.roc"])]),
			Task("sbom-tool", [Use("sbom"), Run(["blueprint-sbom"])]),
			Task("docs", [Use("docs"), Run(["roc-docs", "build"])]),
			Task(
				"docs-path",
				[Use("docs"), Run(["sh", "-c", "realpath \"$(command -v roc-docs)\""])],
			),
			Task(
				"install-snippet",
				[Use("dev"), Run(["scripts/write_install_snippet.roc"])],
			),
			Task("site", [Use("dev"), Run(["scripts/build_site.roc"])]),
			Task("serve", [Use("dev"), Run(["scripts/serve_site.roc"])]),
			Task("capture", [Use("dev"), Run(["scripts/capture_example.roc"])]),
		]
	}

	## The composition weaver's prepare-sbom task wrote for 0.10.1, with the
	## supplier SBOMs fetch-dependency-sboms recorded, as sbom-sidecars merged
	## them.
	weaver_composition : Str
	weaver_composition = {
		listing : Try(Profile.Listing, _)
		listing = Json.parse(weaver_members)
		members = (listing ?? { archive: "", sha256: "", members: [] }).members
		id = |m| "member-${m.name.replace_each(".", "-")}"
		components = members.map(
			|m| {
				id: id(m),
				name: m.name,
				version: "sha256-${m.sha256}",
				identity: "urn:blueprint:archive-member:${m.name}:${m.sha256}",
				download: "NOASSERTION",
				sha256: m.sha256,
				license: "UPL-1.0 AND MIT",
				license_url: "",
				modified: "",
				target: "source",
				origin: "reviewed",
				producer: "Person: Luke Boswell",
			},
		)
		relationships = members.map(
			|m| {
				from: "weaver",
				to: id(m),
				relation: "contains",
				scope: "",
				basis: "Archive member checked against committed source; SHA-256 "
					.concat("identifies the member bytes."),
			},
		)
		inner = |text| text.drop_prefix("[").drop_suffix("]")
		reviewed = weaver_package
			.replace_each("\"@ARCHIVE_COMPONENTS@\"", inner(Json.to_str(components)))
			.replace_each(
				"\"@ARCHIVE_RELATIONSHIPS@\"",
				inner(Json.to_str(relationships)),
			)
			.replace_each("@RELEASE@", "0.10.1")
			.replace_each("@COMMIT@", "1add20ab63f801825572d10c299f0824533e8237")
			.replace_each(
				"@BUNDLE_URL@",
				"https://github.com/lukewilliamboswell/weaver/releases/download/0.10.1"
					.concat("/${bundle}"),
			)
			.replace_each(
				"@BUNDLE_SHA256@",
				"d77a3cf330aa09b7688900a11765d4760f6625887ca73bdac3e4b8bb08f55234",
			)
			.replace_each(
				"@COMPILER_SHA256@",
				"cfcd6944dfd22fc92c9e79aaec08b1a208c6f869f0389ba04fd58c468970cb98",
			)
			.replace_each("@COMPILER@", "nightly-2026-11-02-847b82c")
		supplied : Try({ imported_documents : List(Profile.Imported) }, _)
		supplied = Json.parse(weaver_imports)
		composition : Try(Profile.Composition, _)
		composition = Json.parse(Profile.normalize_input(reviewed) ?? "")
		none = {
			profile: "",
			imported_documents: [],
			unavailable_sboms: [],
			components: [],
			relationships: [],
			coverage: [],
			inputs: [],
		}
		documents = (supplied ?? { imported_documents: [] }).imported_documents
		Json.to_str({ ..(composition ?? none), imported_documents: documents })
	}

	## The subject sbom-sidecars wrote for the bundle, with the digest and
	## size that kai, which reads no artifact, needs stated.
	weaver_subject : Str
	weaver_subject = Json.to_str({
		filename: bundle,
		version: "0.10.1",
		target: "source",
		sha256: "d77a3cf330aa09b7688900a11765d4760f6625887ca73bdac3e4b8bb08f55234",
		size: 39622.U64,
		url: "${release}/${bundle}",
	})

	## The context sbom-sidecars wrote, naming `generator`.
	weaver_context : Str -> Str
	weaver_context = |generator|
		Json.to_str({
			namespace: "${sbom}/${commit}/${bundle}/revision-1",
			revision: "1",
			created: "2026-11-03T02:28:45Z",
			author: "Person: Luke Boswell",
			generator,
		})
}

systems = ["x86_64-linux", "aarch64-linux", "aarch64-darwin"]

digest = Cases.digest

parse_composition = Cases.parse_composition

renderings = Cases.renderings

inputs_of :
	List(Config.Setting), [Absent, Present(Str)] -> Try(Profile.Inputs, Str)
inputs_of = |settings, lock| {
	model = StdModel.from_settings(settings)?
	Inputs.from(model, lock).map_err(|f| f.message)
}

bundle = "7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst"

gh = "https://github.com"

ansi = "${gh}/lukewilliamboswell/roc-ansi/releases/download/0.13.3"

path_rel = "${gh}/roc-lang/path/releases/download/4.0.0"

release = "${gh}/lukewilliamboswell/weaver/releases/download/0.10.1"

sbom = "${gh}/lukewilliamboswell/weaver/sbom/0.10.1"

commit = "1add20ab63f801825572d10c299f0824533e8237"

## The SHA-256 of weaver 0.10.1's inventory, which its manifest names.
inventory_sha256 =
	"2d116bb7982bd7c2d0b79008ab5aee6cda417b491a5c5e9375f2d21d0396c062"

## The cases' systems, on Kai.
fixture : List(Config.Setting)
fixture = [Name("fixture"), Systems(["x86_64-linux", "aarch64-linux"])]

## The source-import case on Kai: its file source is a FetchAll.
source_import : List(Config.Setting)
source_import = fixture.append(
	FetchAll(
		"dep",
		{
			url: "https://example.org/releases/1.2.0/dep-abc.tar.zst",
			sha256: "3945bb64314f2f25732bb36f3bc7f52a2087cfde17439086cf3acd785e3fdfca",
		},
	),
)

# On Kai, the blueprint cases' settings give their inputs: a FetchAll is
# Blueprint's SourceFile, a file source pinned by its published SHA-256.
expect
	inputs_of(fixture, Absent)
		== Ok({ ..Profile.no_inputs, systems: Cases.systems })
		and inputs_of(source_import, Absent) == Ok(Cases.source_import)

# weaver's Kaifile names the 28 inputs its reviewed composition disposes of.
expect {
	inputs = inputs_of(Release.weaver, Present(weaver_lock))?
	c = parse_composition(Release.weaver_composition)?
	known = Profile.known_inputs(inputs, "source")
	known.len() == 28
		and known.sort_with(Lookup.bytewise)
			== c.inputs.map(|d| d.input).sort_with(Lookup.bytewise)
}

# weaver 0.10.1 on Kai: the inventory is the one its manifest names by
# SHA-256, and each rendering the sidecar its release published.
expect {
	inputs = inputs_of(Release.weaver, Present(weaver_lock))?
	listing : Try(Profile.Listing, _)
	listing = Json.parse(weaver_members)
	members = listing?.members
	composition = parse_composition(Release.weaver_composition)?
	inventory = Profile.inspect_archive(inputs, "source", composition, members)?
	text = "${Json.to_str(inventory)}\n"
	rendered = renderings(
		text,
		Release.weaver_subject,
		Release.weaver_context("Tool: blueprint-sbom-0.11.0"),
	)?
	digest(text) == "2d116bb7982bd7c2d0b79008ab5aee6cda417b491a5c5e9375f2d21d0396"
		.concat("c062")
		and rendered.map(digest)
			== [
				"e825e252345a72628dceeb8590caab52b5fce3c938a4017496d94f7ce1fd2672",
				"7e6e115ec8e5b6cccb9fc1f1d48e4e4f91969e7255ad9f7c8274a46540e3f1cb",
				"9df2d56344cfac99e76940ea7d7e88d4d7e346484bf9009574333543402e709c",
			]
}

## The context of a plan whose files kai read back as `observed`.
context : List(Str),
U64,
List(
	{ path : Str, contents : [Missing, Text(Str)] },
) -> Implementation.Context
context = |args, phase, observed| {
	paths = [
		"composition",
		"members",
		"inventory",
		"subject",
		"context",
		"artifact",
		"output",
		"manifest",
	]
	named = |word| paths.contains(word.drop_prefix("--"))
	var $parsed = []
	var $i = 0
	while $i < args.len() {
		word = args.get($i) ?? ""
		if $i == 0 {
			$parsed = $parsed.append({ name: "action", value: Present(word) })
			$i = $i + 1
		} else if word == "--" {
			$parsed = $parsed.append({
				name: "words",
				value: Many(args.drop_first($i + 1)),
			})
			$i = args.len()
		} else if named(word) {
			$parsed = $parsed.append({
				name: word.drop_prefix("--"),
				value: Present(args.get($i + 1) ?? ""),
			})
			$i = $i + 2
		} else {
			$parsed = $parsed.append(
				{ name: word.drop_prefix("--"), value: Present("") },
			)
			$i = $i + 1
		}
	}
	{
		args: $parsed,
		backend: "",
		host: { system: "x86_64-linux" },
		layout: Layout.{
			project_root: "/project",
			workspace: "/project/.kai",
			generated_root: "/project/.kai/generated",
			lock_path: "/project/.kai/lock.json",
		},
		revision: { describe: "", commit_date: "" },
		lock: Present(weaver_lock),
		phase,
		observed,
	}
}

## The plan `kai sbom` makes for `args` on weaver, phase by phase, with
## `files` the contents of the paths it names.
planned : List(Str), List((Str, Str)) -> Try(Plan, Plan.Failure)
planned = |args, files| {
	plugin = Sbom.plugin(Release.weaver)
	plan_of = |ctx| {
		found = plugin.implementations.first().map_err(|_| Plan.fail("none"))?
		(found.plan)(ctx)
	}
	var $plan = plan_of(context(args, 0, []))?
	var $phase = 1
	while $plan.next != Done {
		observed = match $plan.next {
			Observe(copies) =>
				copies.map(
					|copy| {
						# Each copy's source is the cp step that writes it.
						source = $plan.steps.keep_oks(
							|step|
								match step {
									Run({ argv: ["cp", "--", from, to], .. }) if to == copy => Ok(from)
									_ => Err({})
								},
						).first() ?? ""
						contents = files.find_first(|(path, _)| path == source)
							.map_ok(|(_, text)| Text(text))
							?? Missing
						{ path: copy, contents }
					},
				)
			Done => []
		}
		$plan = plan_of(context(args, $phase, observed))?
		$phase = $phase + 1
	}
	Ok($plan)
}

## The files a plan writes, by the path each is copied to.
written : Plan -> List((Str, Str))
written = |plan| {
	generated = plan.steps.join_map(
		|step|
			match step {
				Write(files) => files
				_ => []
			},
	)
	plan.steps.keep_oks(
		|step|
			match step {
				Run({ argv: ["cp", "--", from, to], .. }) =>
					generated.find_first(|f| f.path == from)
						.map_ok(|f| (to, f.contents))
						.map_err(|_| {})
				_ => Err({})
			},
	)
}

# The whole release on Kai, as the sbom-sidecars action runs it: inspect,
# bind and check write weaver 0.10.1's published sidecars and manifest, and
# with kai-sbom as the generator differ from them only in its name.
expect {
	dist = "/project/dist/${bundle}"
	inspect = planned(
		[
			"inspect",
			"--composition",
			"/s/c.json",
			"--members",
			"/s/m.json",
			"--output",
			"/s/i.json",
			"--",
			"source",
		],
		[("/s/c.json", Release.weaver_composition), ("/s/m.json", weaver_members)],
	)?
	inventory = (written(inspect).first()?).1
	bind = |generator|
		planned(
			[
				"bind",
				"--inventory",
				"/s/i.json",
				"--subject",
				"/s/s.json",
				"--context",
				"/s/x.json",
				"--artifact",
				dist,
			],
			[
				("/s/i.json", inventory),
				("/s/s.json", Release.weaver_subject),
				("/s/x.json", Release.weaver_context(generator)),
			],
		)
	bound = written(bind("Tool: blueprint-sbom-0.11.0")?)
	renamed = written(bind("Tool: kai-sbom-0.0.12")?)
	same_but_name = bound.map(
		|(path, text)| (
			path,
			text.replace_each("blueprint-sbom-0.11.0", "kai-sbom-0.0.12"),
		),
	)
	check = planned(
		[
			"check",
			"--manifest",
			"${dist}.sbom-manifest.json",
			"--inventory",
			"/s/i.json",
		],
		bound.append(("/s/i.json", inventory)),
	)?
	digest(inventory) == "2d116bb7982bd7c2d0b79008ab5aee6cda417b491a5c5e9375f2d21"
		.concat("d0396c062")
		and bound.map(|(path, text)| (path, digest(text)))
			== [
				(
					"${dist}.spdx.json",
					"e825e252345a72628dceeb8590caab52b5fce3c938a4017496d94f7ce1fd2672",
				),
				(
					"${dist}.cdx.json",
					"9df2d56344cfac99e76940ea7d7e88d4d7e346484bf9009574333543402e709c",
				),
				(
					"${dist}.sbom-manifest.json",
					"0a30498a4fe537773bdc7b96aa8aae4247290f0f4c0502086dad3f33d77292c0",
				),
			]
		and renamed.map(|(path, _)| path) == same_but_name.map(|(path, _)| path)
		and renamed.take_first(2) == same_but_name.take_first(2)
		and
		check.steps
			.any(
				|s| s == Print("${dist}.sbom-manifest.json: manifest of ${bundle} checks"),
			)
}
