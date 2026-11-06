# The sbom plugin: `kai sbom`, which inventories a reviewed composition
# against what the project declares and locks, renders the inventory as
# SPDX 3.0.1, SPDX 2.3 and CycloneDX 1.7 sidecars of a release file with an
# evidence manifest, and checks such sidecars. It is pure: kai copies the
# files a command names into the generated root for the plan to read back,
# and copies what it writes there to the paths the command names.
import pf.Command
import pf.Implementation
import pf.LockJson
import pf.Plan
import pf.Plugin
import std.Config
import std.StdModel exposing [Model]
import Inputs
import Lookup
import Manifest
import Profile
import Sidecar

Sbom := [].{

	## `project` is std's settings, whose downloads, environments, tasks and
	## builds are the inputs an inventory disposes of.
	plugin : List(Config.Setting) -> Plugin
	plugin = |project|
		match StdModel.from_settings(project) {
			Ok(model) =>
				Plugin.new({
					name: "sbom",
					version: "",
					describe: "",
					commands: [Sbom.command],
					backends: [],
					implementations: [
						Implementation.{
							command: "sbom",
							backend: Independent,
							fit: |_| Ok({}),
							plan: |ctx| Sbom.plan(model, ctx),
						},
					],
				})
			Err(problem) => Plugin.invalid("sbom", [problem])
		}

	command : Command
	command = Command.{
		name: "sbom",
		summary: "Inventory the project for an SBOM, and write and check SBOMs",
		help: Sbom.page,
		args: [
			Name({
				name: "action",
				help: "What to do.",
				choices: Sbom.actions,
				default: Required,
			}),
			Trailing({
				name: "words",
				help: "inspect: the target; inputs: the target (source if none); check: "
					.concat("the documents"),
				choices: [],
			}),
			Path({
				name: "composition",
				short: "",
				help: "inspect: the reviewed composition JSON",
			}),
			Path({
				name: "members",
				short: "",
				help: "inspect: the source archive's member listing",
			}),
			Path({
				name: "inventory",
				short: "",
				help: "bind, check: the inventory inspect wrote",
			}),
			Path({ name: "subject", short: "", help: "bind: the subject JSON" }),
			Path(
				{ name: "context", short: "", help: "bind: the document context JSON" },
			),
			Path({
				name: "artifact",
				short: "",
				help: "bind: the release file the sidecars describe",
			}),
			Path({
				name: "output",
				short: "",
				help: "inspect, bind: where to write; stdout when absent for inspect",
			}),
			Path({
				name: "manifest",
				short: "",
				help: "bind, check: the evidence manifest",
			}),
			Flag({
				name: "spdx-2-3",
				short: "",
				help: "bind: write SPDX 2.3 to --output",
			}),
			Flag({
				name: "cyclonedx",
				short: "",
				help: "bind: write CycloneDX 1.7 to --output",
			}),
		],
		lock: ReadsLock,
	}

	actions : List(Command.Choice)
	actions = [
		choice("inputs", "Print the input names a composition must dispose of"),
		choice(
			"pins",
			"Print the locked files and sources, for supplier SBOM fetchers",
		),
		choice(
			"inspect",
			"Check a composition against the project and write its inventory",
		),
		choice("bind", "Render an inventory as SBOM sidecars of a release file"),
		choice("check", "Check SBOM sidecars, their inventory and their manifest"),
	]

	page : Command.Page
	page = {
		description: "Write the SBOMs of a release from the project's declared and "
			.concat("locked inputs: inspect a reviewed composition into an inventory, ")
			.concat("bind it to a release file as SPDX 3.0.1, SPDX 2.3 and CycloneDX ")
			.concat("1.7 sidecars with an evidence manifest, and check them. ")
			.concat("docs/sbom.md describes the files and the profile."),
		examples: [
			"kai sbom inputs",
			"kai sbom inspect --composition dist/sbom-composition.json --output "
				.concat("inventory.json -- source"),
			"kai sbom bind --inventory inventory.json --subject subject.json --context "
				.concat("context.json --artifact dist/app.tar.zst"),
			"kai sbom check --manifest dist/app.tar.zst.sbom-manifest.json --inventory "
				.concat("inventory.json"),
		],
		config: [],
	}

	## The plan for one action. Actions that read files take two phases, or
	## three when a manifest names more: copy them into the generated root
	## and observe them, then work from what was read.
	plan : Model, Implementation.Context -> Try(Plan, Plan.Failure)
	plan = |model, ctx| {
		words = Command.trailing(ctx.args, "words")
		match Command.name(ctx.args, "action") {
			"inputs" => {
				inputs = Inputs.from(model, ctx.lock)?
				target = match words {
					[] => "source"
					[one] => one
					_ => return Err(Plan.fail("inputs takes at most one target"))
				}
				target_known(inputs, target)?
				names = Profile.known_inputs(inputs, target)
					.sort_with(Lookup.bytewise)
				Ok(printed(Str.join_with(names, "\n")))
			}
			"pins" => {
				inputs = Inputs.from(model, ctx.lock)?
				Ok(printed(Sbom.pins(inputs)))
			}
			"inspect" => Sbom.inspect(model, ctx, words)
			"bind" => Sbom.bind(ctx, words)
			"check" => Sbom.check(ctx, words)
			other => Err(Plan.fail("unknown sbom action: ${other}"))
		}
	}

	## `inspect`: the composition, checked against the project's inputs for
	## the target, as an inventory.
	inspect : Model, Implementation.Context, List(Str) -> Try(Plan, Plan.Failure)
	inspect = |model, ctx, words| {
		target = match words {
			[one] => one
			_ => return Err(
				Plan.fail("inspect needs the target after --: source or a system"),
			)
		}
		composition = required(ctx, "composition")?
		members = Command.path(ctx.args, "members")
		files = [("composition", composition)]
			.concat(
				match members {
					Ok(listing) => [("members", listing)]
					Err(_) => []
				},
			)
		if ctx.phase == 0 {
			# Refuse a project the lock does not cover before reading anything.
			_ = Inputs.from(model, ctx.lock)?
			return Ok(staged(ctx, files))
		}
		inputs = Inputs.from(model, ctx.lock)?
		text = read(ctx, "composition")?
		parsed : Try(Profile.Composition, _)
		parsed = Json.parse(Profile.normalize_input(text).map_err(Plan.fail)?)
		found = parsed.map_err(
			|_| Plan.fail("${composition} is not an SBOM composition"),
		)?
		inventory = match members {
			Ok(listing_path) => {
				listing : Try(Profile.Listing, _)
				listing = Json.parse(read(ctx, "members")?)
				listed = listing.map_err(
					|_| Plan.fail("${listing_path} is not a member listing"),
				)?
				Profile.inspect_archive(inputs, target, found, listed.members)
			}
			Err(_) => Profile.inspect(inputs, target, found)
		}
		written = "${Json.to_str(inventory.map_err(Plan.fail)?)}\n"
		match Command.path(ctx.args, "output") {
			Ok(output) => Ok(emitted(ctx, [{ path: output, contents: written }]))
			Err(_) => Ok(printed(written.drop_suffix("\n")))
		}
	}

	## `bind`: the inventory rendered for the subject, every document and the
	## manifest before any is written, so a refusal writes nothing. Without
	## --output, SPDX 3.0.1 and CycloneDX 1.7 and the manifest go beside the
	## artifact.
	bind : Implementation.Context, List(Str) -> Try(Plan, Plan.Failure)
	bind = |ctx, words| {
		if !words.is_empty() {
			return Err(Plan.fail("bind takes no words after --"))
		}
		inventory_path = required(ctx, "inventory")?
		subject_path = required(ctx, "subject")?
		context_path = required(ctx, "context")?
		artifact = required(ctx, "artifact")?
		if ctx.phase == 0 {
			return Ok(
				staged(
					ctx,
					[
						("inventory", inventory_path),
						("subject", subject_path),
						("context", context_path),
					],
				),
			)
		}
		spdx2 = Command.flag(ctx.args, "spdx-2-3")
		cyclonedx = Command.flag(ctx.args, "cyclonedx")
		manifest_option = Command.path(ctx.args, "manifest")
		(outputs, manifest_path) = match Command.path(ctx.args, "output") {
			Ok(output) => {
				format = match (spdx2, cyclonedx) {
					(
						Bool.True,
						Bool.True,
					) => return Err(Plan.fail("--spdx-2-3 and --cyclonedx do not combine"))
					(Bool.True, _) => "spdx-2.3"
					(_, Bool.True) => "cyclonedx-1.7"
					_ => "spdx-3.0.1"
				}
				([(output, format)], manifest_option ?? "")
			}
			Err(_) => {
				if spdx2 or cyclonedx or manifest_option.is_ok() {
					return Err(
						Plan.fail("--spdx-2-3, --cyclonedx and --manifest need --output"),
					)
				}
				(
					[
						("${artifact}.spdx.json", "spdx-3.0.1"),
						("${artifact}.cdx.json", "cyclonedx-1.7"),
					],
					"${artifact}${Manifest.suffix}",
				)
			}
		}
		inventory_text = read(ctx, "inventory")?
		subject_text = Profile.normalize_input(read(ctx, "subject")?)
			.map_err(Plan.fail)?
		inventory_parsed : Try(Profile.Inventory, _)
		inventory_parsed = Json.parse(
			Profile.normalize_input(inventory_text).map_err(Plan.fail)?,
		)
		inventory = inventory_parsed.map_err(
			|_| Plan.fail("${inventory_path} is not an inventory"),
		)?
		subject_parsed : Try(Profile.Subject, _)
		subject_parsed = Json.parse(subject_text)
		subject = subject_parsed.map_err(
			|_| Plan.fail("${subject_path} is not a subject"),
		)?
		context_parsed : Try(Profile.Context, _)
		context_parsed = Json.parse(read(ctx, "context")?)
		context = context_parsed.map_err(
			|_| Plan.fail("${context_path} is not a context"),
		)?
		if Manifest.file_name_of(artifact) != subject.filename {
			return Err(Plan.fail("subject filename differs from final artifact"))
		}
		if outputs.any(|(output, _)| output == artifact) or
			manifest_path == artifact {
			return Err(Plan.fail("sidecar must not overwrite subject"))
		}
		if outputs.any(|(output, _)| output == manifest_path) {
			return Err(Plan.fail("manifest must not overwrite a sidecar"))
		}
		directory = Manifest.directory_of(manifest_path)
		beside = |output| Manifest.directory_of(output) == directory
		if !manifest_path.is_empty() and !outputs.all(|(output, _)| beside(output)) {
			return Err(Plan.fail("the manifest must sit beside the sidecars it lists"))
		}
		# kai reads no artifact bytes, so the subject states them.
		if subject.sha256.is_empty() {
			return Err(
				Plan.fail("${subject_path} must state the sha256 of ${subject.filename}"),
			)
		}
		documents = outputs.map_try(
			|(output, format)| {
				render = match format {
					"spdx-2.3" => Profile.render_spdx2
					"cyclonedx-1.7" => Profile.render_cyclonedx
					_ => Profile.render
				}
				contents = render(inventory, subject, context).map_err(Plan.fail)?
				Ok({ path: output, format, contents })
			},
		)?
		manifests = if manifest_path.is_empty() {
			[]
		} else {
			sized : Try({ size : U64 }, _)
			sized = Json.parse(subject_text)
			size = sized.map_err(
				|_| Plan.fail(
					"${subject_path} must state the size of ${subject.filename} "
						.concat("for the manifest"),
				),
			)?
				.size
			sidecars = documents.map(
				|d| {
					filename: Manifest.file_name_of(d.path),
					format: d.format,
					sha256: digest(d.contents),
					size: d.contents.to_utf8().len(),
				},
			)
			text = Manifest.render({
				profile: Profile.profile,
				subject: {
					filename: subject.filename,
					version: subject.version,
					target: subject.target,
					sha256: subject.sha256,
					size,
				},
				inventory_sha256: digest(inventory_text),
				context: {
					namespace: context.namespace,
					revision: context.revision,
					created: context.created,
					generator: context.generator,
				},
				sidecars,
			}).map_err(Plan.fail)?
			[{ path: manifest_path, contents: text }]
		}
		Ok(
			emitted(
				ctx,
				documents.map(|d| { path: d.path, contents: d.contents }).concat(manifests),
			),
		)
	}

	## `check`: each document held to the profile and to the inventory, the
	## manifest to the sidecars it lists and the inventory, and the
	## renderings of one subject to one graph. The subject's own bytes are
	## not read: compare its SHA-256 with what the manifest states.
	check : Implementation.Context, List(Str) -> Try(Plan, Plan.Failure)
	check = |ctx, documents| {
		manifest = Command.path(ctx.args, "manifest")
		inventory = Command.path(ctx.args, "inventory")
		if documents.is_empty() and manifest.is_err() {
			return Err(Plan.fail("check needs at least one SBOM document"))
		}
		named = documents.map_with_index(|path, i| ("document-${i.to_str()}", path))
		given = named
			.concat(
				match manifest {
					Ok(path) => [("manifest", path)]
					Err(_) => []
				},
			)
			.concat(
				match inventory {
					Ok(path) => [("inventory", path)]
					Err(_) => []
				},
			)
		if ctx.phase == 0 {
			return Ok(staged(ctx, given))
		}
		listed = match manifest {
			Ok(path) => {
				text = read(ctx, "manifest")?
				found = Manifest.read(text).map_err(|why| Plan.fail("${path}: ${why}"))?
				found.sidecars.map_with_index(
					|entry, i| ("listed-${i.to_str()}", Manifest.beside(path, entry.filename)),
				)
			}
			Err(_) => []
		}
		if ctx.phase == 1 and !listed.is_empty() {
			return Ok(staged(ctx, given.concat(listed)))
		}
		Sbom.checked(ctx, named, listed, manifest, inventory)
	}

	## The checks of `check`, once every file is read.
	checked :
		Implementation.Context,
		List((Str, Str)),
		List((Str, Str)),
		Try(
			Str,
			[NoValue],
		),
		Try(Str, [NoValue]) -> Try(Plan, Plan.Failure)
	checked = |ctx, named, listed, manifest_path, inventory_path| {
		fail = |path, why| Plan.fail("${path}: ${why}")
		inventory_text = match inventory_path {
			Ok(_) => Ok(read(ctx, "inventory")?)
			Err(_) => Err(NoInventory)
		}
		inventory = match (inventory_path, inventory_text) {
			(Ok(path), Ok(text)) => {
				parsed : Try(Profile.Inventory, _)
				parsed = Json.parse(
					Profile.normalize_input(text).map_err(
						|why| fail(
							path,
							why,
						),
					)?,
				)
				Ok(parsed.map_err(|_| fail(path, "not an inventory"))?)
			}
			_ => Err(NoInventory)
		}
		verified = match manifest_path {
			Ok(path) => {
				text = read(ctx, "manifest")?
				found = Manifest.read(text).map_err(|why| fail(path, why))?
				sidecars = listed.map_try(
					|(role, sidecar)| {
						contents = read(ctx, role)?
						Ok({
							filename: Manifest.file_name_of(sidecar),
							sha256: digest(contents),
							size: contents.to_utf8().len(),
						})
					},
				)?
				measured = match inventory_text {
					Ok(t) => Measured(digest(t))
					Err(_) => Unmeasured
				}
				observed = {
					subject: { sha256: found.subject.sha256, size: found.subject.size },
					inventory: measured,
					sidecars,
				}
				Ok(Manifest.check(text, observed).map_err(|why| fail(path, why))?)
			}
			Err(_) => Err(NoManifest)
		}
		listed_paths = listed.map(|(_, path)| path)
		order = listed.concat(named.drop_if(|(_, path)| listed_paths.contains(path)))
		var $checked = []
		var $lines = []
		for (role, path) in order {
			one = Sidecar.check(read(ctx, role)?).map_err(|why| fail(path, why))?
			match inventory {
				Ok(stated) => Sidecar.against_inventory(one, stated).map_err(
					|why| fail(
						path,
						why,
					),
				)?
				Err(_) => {}
			}
			match verified {
				Ok(m) if listed_paths.contains(path) or
					one.subject.name == m.subject.filename => {
					name = if (listed_paths.contains(path)) Manifest.file_name_of(path) else ""
					Manifest.describes(m, name, one).map_err(|why| fail(path, why))?
				}
				_ => {}
			}
			for earlier in $checked {
				same_document = earlier.document.namespace == one.document.namespace
				other_version = earlier.document.version != one.document.version
				if same_document and other_version and !Sidecar.same_graph(earlier, one) {
					return Err(
						fail(
							path,
							"the ${earlier.document.version} and ${one.document.version} "
								.concat("renderings of ${one.subject.name} differ"),
						),
					)
				}
			}
			$checked = $checked.append(one)
			$lines = $lines.append(
				Print(
					"${path}: ${one.document.version} sidecar of ${one.subject.name} "
						.concat("checks"),
				),
			)
		}
		tail = match (manifest_path, verified) {
			(Ok(path), Ok(m)) => [
				Print("${path}: manifest of ${m.subject.filename} checks"),
				Note(
					"kai sbom: ${m.subject.filename} itself was not read; compare its "
						.concat("SHA-256 with ${m.subject.sha256}"),
				),
			]
			_ => []
		}
		Ok(Plan.{ steps: $lines.concat(tail), next: Done })
	}

	## The lock report supplier SBOM fetchers read, `blueprint lock show
	## --json`'s format 2: each file source by name with its flat SHA-256,
	## and each downloaded file.
	pins : Profile.Inputs -> Str
	pins = |inputs| {
		s = |value| String(value)
		file_digest = |source| if (source.provider == "file") source.digest
			.drop_prefix("sha256:") else ""
		sources = inputs.sources.map(
			|source| {
				name: source.name,
				value: Object([
					{ name: "content_identity", value: s(source.digest) },
					{ name: "digest", value: s(source.digest) },
					{
						name: "digestKind",
						value: s(if (source.provider == "file") "file" else "tree"),
					},
					{ name: "flatSha256", value: s(file_digest(source)) },
					{ name: "name", value: s(source.name) },
					{ name: "provider", value: s(source.provider) },
					{ name: "ref", value: s(source.ref) },
					{ name: "rev", value: s(source.rev) },
				]),
			},
		)
		fetched = inputs.fetched.map(
			|f|
				Object([
					{ name: "content_identity", value: s("sha256:${f.sha256}") },
					{ name: "name", value: s(f.name) },
					{ name: "sha256", value: s(f.sha256) },
					{ name: "system", value: s(f.system) },
					{ name: "urls", value: Array(f.urls.map(s)) },
				]),
		)
		LockJson.encode(
			Object([
				{ name: "format", value: Number("2") },
				{ name: "sources", value: Object(sources) },
				{ name: "fetched", value: Array(fetched) },
			]),
		)
	}
}

choice : Str, Str -> Command.Choice
choice = |value, summary| { value, summary, details: [] }

## A plan that prints `text` on stdout.
printed : Str -> Plan
printed = |text| Plan.{ steps: [Print(text)], next: Done }

digest : Str -> Str
digest = |text| Crypto.SHA256.hash(text.to_utf8()).to_hex()

## The absolute path a required Path argument names.
required : Implementation.Context, Str -> Try(Str, Plan.Failure)
required = |ctx, name|
	Command.path(ctx.args, name)
		.map_err(
			|_| {
				action = Command.name(ctx.args, "action")
				Plan.fail("kai sbom ${action} needs --${name}")
			},
		)

## Where kai copies an input file the plan reads back.
copy_of : Implementation.Context, Str -> Str
copy_of = |ctx, role| "${ctx.layout.generated_root}/sbom/input/${role}"

## Copy each (role, path) into the generated root, then read the copies.
staged : Implementation.Context, List((Str, Str)) -> Plan
staged = |ctx, files| {
	steps = files.map(
		|(role, path)|
			Run({
				description: "read ${path}",
				argv: ["cp", "--", path, copy_of(ctx, role)],
				output: Quiet,
				secrets: [],
				removed_environment_variables: [],
				kept_environment_variables: [],
			}),
	)
	# Writing a file there makes the directory the copies go into.
	Plan.{
		steps: [
			Write([
				{
					path: "${ctx.layout.generated_root}/sbom/input/.keep",
					contents: "",
				},
			]),
		].concat(steps),
		next: Observe(files.map(|(role, _)| copy_of(ctx, role))),
	}
}

## The text of the file read back for `role`.
read : Implementation.Context, Str -> Try(Str, Plan.Failure)
read = |ctx, role|
	match ctx.observed.find_first(|o| o.path == copy_of(ctx, role)) {
		Ok({ contents: Text(text), .. }) => {
			if !Profile.json_within_bounds(text) {
				return Err(Plan.fail("the ${role} file exceeds 1MiB or depth 64"))
			}
			Ok(text)
		}
		_ => Err(Plan.fail("kai did not read the ${role} file"))
	}

## Write each file in the generated root, then copy it to its path.
emitted : Implementation.Context, List(Plan.File) -> Plan
emitted = |ctx, files| {
	generated = files.map_with_index(
		|file, i| {
			path: "${ctx.layout.generated_root}/sbom/output/${i.to_str()}"
				.concat("-${Manifest.file_name_of(file.path)}"),
			contents: file.contents,
		},
	)
	copies = files.map_with_index(
		|file, i|
			Run({
				description: "write ${file.path}",
				argv: ["cp", "--", (generated.get(i) ?? file).path, file.path],
				output: Quiet,
				secrets: [],
				removed_environment_variables: [],
				kept_environment_variables: [],
			}),
	)
	Plan.{
		steps: [Write(generated)].concat(copies).concat(files.map(|f| Print(f.path))),
		next: Done,
	}
}

## A target is `source` or one of the project's systems.
target_known : Profile.Inputs, Str -> Try({}, Plan.Failure)
target_known = |inputs, target|
	if target == "source" or inputs.systems.contains(target) {
		Ok({})
	} else {
		Err({
			code: "unknown_name",
			message: "unknown target: ${target}",
			hint: "",
			suggestions: Plan.closest(target, inputs.systems.append("source")),
		})
	}
