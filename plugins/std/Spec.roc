# `kai spec`: std's model as the documented JSON of docs/spec.md, for tools
# such as SBOM generators. Read-only: it needs no lock, backend or network.
import Config
import ConfigToModel
import pf.LockJson
import model.Model
import model.Project

Spec := [].{

	## Bumped only when a field changes meaning or goes away; new fields keep it.
	schema_version : U64
	schema_version = 1

	json : Model -> Str
	json = |model| {
		fetched = |name| model.fetches.any(|f| f.name == name)
		tool = |t|
			if fetched(t.source) {
				from = [("from", text("download")), ("fetch", text(t.source))]
				with_name(t.name, from)
			} else {
				from = [("from", text("package")), ("source", text(t.source))]
				with_name(t.name, from)
			}
		expected = |program| with_name(program, [("from", text("expected"))])
		tools = |listed| Array(listed.map(tool))
		input_kind = |name|
			if model.build_sources.any(|s| s.name == name) {
				"source"
			} else if fetched(name) {
				"fetch"
			} else {
				"cargo_vendor"
			}
		package_variable = |{ name, value }| {
			(kind, listed) = match value {
				LibraryPath(many) => ("library_path", many)
				BinPath(many) => ("bin_path", many)
				PackagePath(one) => ("package_path", [one])
			}
			with_name(name, [("kind", text(kind)), ("tools", tools(listed))])
		}
		alias = |a|
			with_name(a.name, [("tool", tool(a.tool)), ("binary", text(a.binary))])
		environment = |e|
			with_name(
				e.name,
				[
					(
						"tools",
						Array(e.tools.map(tool).concat(e.expected.map(expected))),
					),
					("overlays", texts(e.overlays)),
					("env", variables(e.env)),
					("package_env", Array(e.package_env.map(package_variable))),
					("pure", Boolean(e.pure)),
					("aliases", Array(e.aliases.map(alias))),
					("roc_packages", texts(e.roc_packages.map(Project.roc_package_fetch))),
					(
						"rust_toolchain",
						match e.rust_toolchain {
							None => Null
							Toml({ text: toml, components, target_triples }) =>
								object([
									("toml", text(toml)),
									("components", texts(components)),
									("targets", texts(target_triples)),
								])
						},
					),
					(
						"on_systems",
						Array(
							e.on_systems.map(
								|on|
									object([
										("systems", texts(on.systems)),
										("tools", tools(on.tools)),
										("env", variables(on.env)),
									]),
							),
						),
					),
				],
			)
		file = |fetch_name, f|
			object([
				("key", text("${fetch_name}/${f.system}")),
				("system", text(f.system)),
				("url", text(f.url)),
				("mirrors", texts(f.mirrors)),
				("hash", if (f.hash.is_empty()) Null else file_sha256(f.hash)),
				(
					"archive_path",
					match f.unpack {
						File => Null
						Archive(path) => text(path)
					},
				),
			])
		fetch = |f| {
			locked = Project.locked_fetch(model, f.name)
			with_name(
				f.name,
				[
					("pinned_by", text(if (locked) "lock" else "hash")),
					("files", Array(f.files.map(|one| file(f.name, one)))),
					("unavailable_on", texts(f.unavailable)),
				],
			)
		}
		input = |name| with_name(name, [("kind", text(input_kind(name)))])
		build = |b|
			with_name(
				b.name,
				[
					("description", text(b.description)),
					("environment", text(b.environment)),
					("run", texts(b.run)),
					("output", text(b.output)),
					("inputs", Array(b.inputs.map(input))),
					("needs", texts(b.needs)),
					(
						"files",
						match b.files {
							All => Null
							Only(paths) => texts(paths)
						},
					),
					("env", variables(b.env)),
					("revision", Boolean(b.revision)),
					("default", Boolean(b.default)),
				],
			)
		task = |t|
			with_name(
				t.name,
				[
					("description", text(t.description)),
					("environment", text(t.environment)),
					("run", texts(t.run)),
					("dir", text(t.dir)),
					("env", variables(t.env)),
					("secrets", texts(t.secrets)),
					(
						"optional_environment_variables",
						texts(t.optional_environment_variables),
					),
					("needs", texts(t.needs)),
				],
			)
		step = |workflow_step| {
			# The verbs of kai's step_started events.
			(action, name, args) = match Project.wrapped(workflow_step) {
				RunTask(task_name, words) => ("run", task_name, words)
				BuildArtifact(build_name) => ("build", build_name, [])
				RunWorkflow(workflow_name) => ("workflow", workflow_name, [])
				MayFail(_) => ("", "", [])
			}
			object([
				("action", text(action)),
				("name", text(name)),
				("args", texts(args)),
				("may_fail", Boolean(Project.wrapped(workflow_step) != workflow_step)),
			])
		}
		package_source = |s| {
			(provider, ref) = match s.provider {
				Auto => ("auto", Null)
				NixPackages(flake) => ("nix", text(flake))
				GuixPackages(specification) => ("guix", text(specification))
			}
			with_name(s.name, [("provider", text(provider)), ("ref", ref)])
		}
		follows = |overlay|
			model.follows.keep_if(|f| f.overlay == overlay).map(
				|f| object([("input", text(f.input)), ("source", text(f.source))]),
			)
		overlay = |i|
			with_name(
				i.name,
				[("ref", text(i.url)), ("follows", Array(follows(i.name)))],
			)
		reference = |name, ref| with_name(name, [("ref", text(ref))])
		shell = |s|
			with_name(
				s.name,
				[
					("description", text(s.description)),
					("environment", text(s.environment)),
				],
			)
		workflow = |w|
			with_name(
				w.name,
				[
					("description", text(w.description)),
					("steps", Array(w.steps.map(step))),
				],
			)
		LockJson.encode(
			object([
				("schema_version", Number(Spec.schema_version.to_str())),
				("name", text(model.name)),
				("systems", texts(model.systems)),
				("build_root", text(model.build_root)),
				("package_sources", Array(model.sources.map(package_source))),
				(
					"overlays",
					Array(model.inputs.keep_if(|i| i.kind == Overlay).map(overlay)),
				),
				(
					"flake_inputs",
					Array(
						model.inputs.keep_if(|i| i.kind == Flake)
							.map(|i| reference(i.name, i.url)),
					),
				),
				(
					"sources",
					Array(model.build_sources.map(|s| reference(s.name, s.ref))),
				),
				("fetches", Array(model.fetches.map(fetch))),
				(
					"cargo_vendors",
					Array(model.cargo_vendors.map(|c| with_name(c.name, []))),
				),
				("environments", Array(model.environments.map(environment))),
				("shells", Array(model.shells.map(shell))),
				("tasks", Array(model.tasks.map(task))),
				("builds", Array(model.builds.map(build))),
				("workflows", Array(model.workflows.map(workflow))),
			]),
		)
	}
}

object : List((Str, LockJson)) -> LockJson
object = |fields| Object(fields.map(|(name, value)| { name, value }))

## An object whose first field is `name`.
with_name : Str, List((Str, LockJson)) -> LockJson
with_name = |name, fields| object([("name", text(name))].concat(fields))

text : Str -> LockJson
text = |value| String(value)

## A file's SHA-256 in `kai lock`'s hash shape; the model keeps it as SRI.
file_sha256 : Str -> LockJson
file_sha256 = |sri|
	object([
		("algorithm", text("sha256")),
		("of", text("file")),
		("encoding", text("sri")),
		("value", text(sri)),
	])

texts : List(Str) -> LockJson
texts = |values| Array(values.map(text))

variables : List(Model.Variable) -> LockJson
variables = |listed|
	Array(
		listed.map(|v| with_name(v.name, [("value", text(v.value))])),
	)

# The value at `path` in `settings`' spec: object field names, or array
# indexes as digits.
spec_at : List(Config.Setting), List(Str) -> Try(LockJson, Str)
spec_at = |settings, path| {
	var $value = LockJson.decode(Spec.json(ConfigToModel.convert(settings)?))?
	for segment in path {
		$value = match U64.from_str(segment) {
			Ok(index) =>
				LockJson.array($value)?.get(index).map_err(|_| "no ${segment}")?
			Err(_) => LockJson.field($value, segment)?
		}
	}
	Ok($value)
}

empty_sha256 = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="

linux = "x86_64-linux"

roc_hash = "6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS"

roc_package = "https://example.com/1.0/${roc_hash}.tar.zst"

project : List(Config.Setting)
project = [
	Name("spec"),
	Systems([linux, "aarch64-linux"]),
	Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
	Source("assets", "path:./assets"),
	Fetch(
		"jq",
		[{ system: linux, url: "https://example.com/jq", sha256: empty_sha256 }],
	),
	FetchLocked(
		"tool",
		[
			{
				system: linux,
				url: "https://example.com/t.tar.gz",
				mirrors: [],
				program: Archive("t/tool"),
			},
		],
	),
	FetchUnavailable("jq", ["aarch64-linux"]),
	FetchUnavailable("tool", ["aarch64-linux"]),
	Environment(
		"dev",
		[
			Tools(["git", "stable#hello", "jq#jq", "tool#tool"]),
			Expect(["make"]),
			RocPackages([roc_package]),
		],
	),
	Shell("default", [Use("dev")]),
	Environment("make", [Tools(["gnumake"])]),
	Build(
		"app",
		[Use("make"), Run(["make"]), Output("out"), Inputs(["assets", "jq"])],
	),
	Workflow("ci", [BuildArtifact("app"), MayFail(BuildArtifact("app"))]),
]

# Tools say where they come from: a package source, a download, or the
# machine; fetch files carry the key the lock's direct section uses, and an
# environment's RocPackages are fetches on every system.
expect {
	tools = ["environments", "0", "tools"]
	locked_file = ["fetches", "1", "files", "0"]
	make = Object([
		{ name: "name", value: String("make") },
		{ name: "from", value: String("expected") },
	])
	[
		(["schema_version"], Number("1")),
		(["package_sources", "0", "provider"], String("auto")),
		(["package_sources", "1", "ref"], String("github:NixOS/nixpkgs/nixos-24.05")),
		(tools.concat(["0", "source"]), String("default")),
		(tools.concat(["1", "source"]), String("stable")),
		(tools.concat(["2", "from"]), String("download")),
		(tools.concat(["3", "fetch"]), String("tool")),
		(tools.concat(["4"]), make),
		(["fetches", "0", "pinned_by"], String("hash")),
		(["fetches", "0", "unavailable_on", "0"], String("aarch64-linux")),
		(["fetches", "1", "pinned_by"], String("lock")),
		(locked_file.concat(["key"]), String("tool/x86_64-linux")),
		(["fetches", "0", "files", "0", "hash", "of"], String("file")),
		(["fetches", "0", "files", "0", "hash", "value"], String(empty_sha256)),
		(locked_file.concat(["hash"]), Null),
		(locked_file.concat(["archive_path"]), String("t/tool")),
		(["builds", "0", "inputs", "0", "kind"], String("source")),
		(["builds", "0", "inputs", "1", "kind"], String("fetch")),
		(["builds", "0", "files"], Null),
		(["workflows", "0", "steps", "1", "action"], String("build")),
		(["workflows", "0", "steps", "1", "may_fail"], Boolean(Bool.True)),
		(["shells", "0", "environment"], String("dev")),
		(["environments", "0", "roc_packages", "0"], String("roc-${roc_hash}")),
		(["fetches", "2", "pinned_by"], String("lock")),
		(["fetches", "2", "files", "1", "system"], String("aarch64-linux")),
		(["fetches", "2", "files", "1", "archive_path"], String("main.roc")),
	].all(|(path, expected)| spec_at(project, path) == Ok(expected))
}
