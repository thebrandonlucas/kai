# std's model of a project: what its Kaifile settings declare.
import api.Sexpr
import Value

## Versioned semantic configuration, independent of provider selection or host.
## Major 2 replaces shell packages with reusable environments and source intent.
## Tool names remain provider-native strings, not translated package names.
## Parents are resolved by Project.validate, parent first with first-occurrence
## deduplication. Shells and tasks refer directly to environment identities.
## Consumers must reject unknown required features before deriving effects.
Model := {
	format : { major : U64, minor : U64 },
	name : Str,
	requires_ : List(Str),
	systems : List(Str),
	sources : List(
		{ name : Str, provider : [Auto, NixPackages(Str), GuixPackages(Str)] },
	),
	guix_channels : List(
		{
			name : Str,
			url : Str,
			branch : Str,
			introduction : { commit : Str, signer : Str },
		},
	),
	inputs : List({ name : Str, url : Str, kind : [Overlay, Flake] }),
	follows : List({ overlay : Str, input : Str, source : Str }),
	environments : List(
		{
			name : Str,
			parents : List(Str),
			tools : List({ source : Str, name : Str }),
			overlays : List(Str),
			env : List({ name : Str, value : Str }),
			pure : Bool,
			aliases : List(
				{ name : Str, tool : { source : Str, name : Str }, binary : Str },
			),
			rust_toolchain : [None, Toml(Str)],
			package_env : List(
				{
					name : Str,
					value : [
						LibraryPath(List({ source : Str, name : Str })),
						BinPath(List({ source : Str, name : Str })),
						PackagePath({ source : Str, name : Str }),
					],
				},
			),
		},
	),
	shells : List({ name : Str, environment : Str, description : Str }),
	tasks : List(
		{
			name : Str,
			environment : Str,
			run : List(Str),
			env : List({ name : Str, value : Str }),
			secrets : List(Str),
			optional_environment_variables : List(Str),
			needs : List(Str),
			description : Str,
		},
	),
	build_sources : List({ name : Str, ref : Str }),
	fetches : List(
		{ name : Str, files : List({ system : Str, url : Str, hash : Str }) },
	),
	cargo_vendors : List({ name : Str, lock : Str }),
	builds : List(
		{
			name : Str,
			environment : Str,
			inputs : List(Str),
			needs : List(Str),
			run : List(Str),
			output : Str,
			files : [All, Only(List(Str))],
			env : List({ name : Str, value : Str }),
			revision : Bool,
			description : Str,
		},
	),
	workflows : List(
		{
			name : Str,
			description : Str,
			steps : List(
				[
					RunTask(Str, List(Str)),
					BuildArtifact(Str),
					RunWorkflow(Str),
					MayFail([RunTask(Str, List(Str)), BuildArtifact(Str), RunWorkflow(Str)]),
				],
			),
		},
	),
	extensions : List({ kind : Str, name : Str, value : Value }),
	raw : List({ backend : Str, target : Str, value : Value }),
}.{
	is_eq : _
	encoder_for : _

	Format : { major : U64, minor : U64 }
	Provider : [Auto, NixPackages(Str), GuixPackages(Str)]
	Source : { name : Str, provider : Provider }

	## A Guix channel beside Guix's own, authenticated by its introduction:
	## its first signed commit and that signer's OpenPGP fingerprint.
	GuixChannel : {
		name : Str,
		url : Str,
		branch : Str,
		introduction : { commit : Str, signer : Str },
	}
	Input : { name : Str, url : Str, kind : [Overlay, Flake] }

	## Overlay `overlay`'s own flake input `input` is package source `source`.
	Follows : { overlay : Str, input : Str, source : Str }
	Tool : { source : Str, name : Str }
	Environment : {
		name : Str,
		parents : List(Str),
		tools : List(Tool),
		overlays : List(Str),
		env : List(Variable),
		pure : Bool,
		aliases : List(Alias),
		rust_toolchain : RustToolchain,
		package_env : List(PackageVariable),
	}

	## The text of a rust-toolchain.toml, whose [toolchain] table the backend
	## reads.
	RustToolchain : [None, Toml(Str)]

	## A variable whose value is a path in packages, which the backend computes:
	## tools' `lib` or `bin` directories joined with `:`, or one tool's path.
	PackageVariable : { name : Str, value : PackageValue }
	PackageValue : [
		LibraryPath(List(Tool)),
		BinPath(List(Tool)),
		PackagePath(Tool),
	]

	## A command `name` on the environment's PATH that runs `binary` from
	## `tool`'s bin directory.
	Alias : { name : Str, tool : Tool, binary : Str }

	## A description, empty when none, summarizes a declaration in help.
	Shell : { name : Str, environment : Str, description : Str }

	## Secrets and optional_environment_variables are the names of variables the
	## task receives, never values; it receives an optional one only when kai's
	## environment sets it.
	## Needs names the builds whose artifacts it reads in `$KAI_ARTIFACTS`.
	Task : {
		name : Str,
		environment : Str,
		run : List(Str),
		env : List(Variable),
		secrets : List(Str),
		optional_environment_variables : List(Str),
		needs : List(Str),
		description : Str,
	}

	## An environment variable. A task's or build's own override its
	## environment's, as an environment's override those of the one it extends.
	Variable : { name : Str, value : Str }

	## Non-flake locked inputs, distinct from package-provider sources.
	BuildSource : { name : Str, ref : Str }

	## A file per system, pinned by its SRI sha256 hash rather than the lock.
	Fetch : { name : Str, files : List(FetchFile) }
	FetchFile : { system : Str, url : Str, hash : Str }

	## The crates a Cargo.lock's text names, vendored into one directory and
	## pinned by the lock's checksums rather than Kai's lock.
	CargoVendor : { name : Str, lock : Str }

	## Run is exact argv. Output is a relative file or directory path; dependencies
	## expose only that artifact, separately from the writable project snapshot.
	## A revision build receives the project's revision in its environment.
	Build : {
		name : Str,
		environment : Str,
		inputs : List(Str),
		needs : List(Str),
		run : List(Str),
		output : Str,
		files : [All, Only(List(Str))],
		env : List(Variable),
		revision : Bool,
		description : Str,
	}

	## Ordered declarations, not command strings or executor recipes.
	Workflow : { name : Str, description : Str, steps : List(WorkflowStep) }
	WorkflowStep : [
		RunTask(Str, List(Str)),
		BuildArtifact(Str),
		RunWorkflow(Str),
		MayFail(Step),
	]
	Step : [RunTask(Str, List(Str)), BuildArtifact(Str), RunWorkflow(Str)]

	## Expansion retains repetitions and extra argv without shell parsing.
	## MayFail(n): the next n steps may fail as one; the rest of them are
	## skipped and the workflow continues.
	AtomicStep : [RunTask(Str, List(Str)), BuildArtifact(Str), MayFail(U64)]

	Extension : { kind : Str, name : Str, value : Value }
	Raw : { backend : Str, target : Str, value : Value }

	current_format : Format
	current_format = { major: 2, minor: 5 }

	empty : Str -> Model
	empty = |name| Model.{
		format: current_format,
		name,
		requires_: [],
		systems: [],
		sources: [],
		guix_channels: [],
		inputs: [],
		follows: [],
		environments: [],
		shells: [],
		tasks: [],
		build_sources: [],
		fetches: [],
		cargo_vendors: [],
		builds: [],
		workflows: [],
		extensions: [],
		raw: [],
	}

	to_str : Model -> Str
	to_str = |model| Str.concat(Sexpr.to_str(model), "\n")

	unsupported_features : Model, List(Str) -> List(Str)
	unsupported_features = |model, supported|
		model.requires_.keep_if(|feature| !supported.contains(feature))
}

# `kai model` and `kai describe` print the model as an S-expression.
expect {
	text = Model.empty("x").to_str()
	text.contains("(major 2)") and text.contains("(name \"x\")")
}
