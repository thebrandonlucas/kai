# Canonical configuration data and its versioned, optional-field wire codec.
import Sexpr
import Value

## Versioned semantic configuration, independent of provider selection or host.
## Major 2 replaces shell packages with reusable environments and source intent.
## Tool names remain provider-native strings, not translated package names.
## Parents are resolved by Project.validate, parent first with first-occurrence
## deduplication. Shells and tasks refer directly to environment identities.
## Missing optional top-level fields default to empty; unknown fields are
## ignored. Consumers must reject unknown required features before deriving
## effects.
Ir := {
	format : { major : U64, minor : U64 },
	name : Str,
	requires_ : List(Str),
	systems : List(Str),
	sources : List(
		{ name : Str, provider : [Auto, NixPackages(Str), GuixPackages(Str)] },
	),
	inputs : List({ name : Str, url : Str, kind : [Overlay, Flake] }),
	environments : List(
		{
			name : Str,
			parents : List(Str),
			tools : List({ source : Str, name : Str }),
			overlays : List(Str),
		},
	),
	shells : List({ name : Str, environment : Str }),
	tasks : List({ name : Str, environment : Str, run : List(Str) }),
	build_sources : List({ name : Str, ref : Str }),
	builds : List(
		{
			name : Str,
			environment : Str,
			inputs : List(Str),
			needs : List(Str),
			run : List(Str),
			output : Str,
		},
	),
	workflows : List(
		{
			name : Str,
			steps : List(
				[
					RunTask(Str, List(Str)),
					BuildArtifact(Str),
					RunWorkflow(Str),
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
	Input : { name : Str, url : Str, kind : [Overlay, Flake] }
	Tool : { source : Str, name : Str }
	Environment : {
		name : Str,
		parents : List(Str),
		tools : List(Tool),
		overlays : List(Str),
	}
	Shell : { name : Str, environment : Str }
	Task : { name : Str, environment : Str, run : List(Str) }

	## Non-flake locked inputs, distinct from package-provider sources.
	BuildSource : { name : Str, ref : Str }

	## Run is exact argv. Output is a relative file or directory path; dependencies
	## expose only that artifact, separately from the writable project snapshot.
	Build : {
		name : Str,
		environment : Str,
		inputs : List(Str),
		needs : List(Str),
		run : List(Str),
		output : Str,
	}

	## Ordered declarations, not command strings or executor recipes.
	Workflow : { name : Str, steps : List(WorkflowStep) }
	WorkflowStep : [RunTask(Str, List(Str)), BuildArtifact(Str), RunWorkflow(Str)]

	## Expansion retains repetitions and extra argv without shell parsing.
	AtomicStep : [RunTask(Str, List(Str)), BuildArtifact(Str)]

	Extension : { kind : Str, name : Str, value : Value }
	Raw : { backend : Str, target : Str, value : Value }

	current_format : Format
	current_format = { major: 2, minor: 2 }

	empty : Str -> Ir
	empty = |name| Ir.{
		format: current_format,
		name,
		requires_: [],
		systems: [],
		sources: [],
		inputs: [],
		environments: [],
		shells: [],
		tasks: [],
		build_sources: [],
		builds: [],
		workflows: [],
		extensions: [],
		raw: [],
	}

	to_str : Ir -> Str
	to_str = |ir| Str.concat(Sexpr.to_str(ir), "\n")

	## Parse the version header before interpreting any version-specific records.
	parse :
		Str ->
			Try(
				Ir,
				[
					InvalidSexpr(Str),
					MissingRequiredField(Str),
					UnsupportedFormat(Format),
				],
			)
	parse = |text| {
		header : { format : Format }
		header = Sexpr.parse(text)?
		if header.format.major != current_format.major {
			return Err(UnsupportedFormat(header.format))
		}
		wire : Wire
		wire = Sexpr.parse(text)?
		Ok(
			Ir.{
				format: wire.format,
				name: wire.name,
				requires_: wire.requires_ ?? [],
				systems: wire.systems ?? [],
				sources: wire.sources ?? [],
				inputs: wire.inputs ?? [],
				environments: wire.environments ?? [],
				shells: wire.shells ?? [],
				tasks: wire.tasks ?? [],
				build_sources: wire.build_sources ?? [],
				builds: wire.builds ?? [],
				workflows: wire.workflows ?? [],
				extensions: wire.extensions ?? [],
				raw: wire.raw ?? [],
			},
		)
	}

	unsupported_features : Ir, List(Str) -> List(Str)
	unsupported_features = |ir, supported|
		ir.requires_.keep_if(|feature| !supported.contains(feature))
}

Wire : {
	format : Ir.Format,
	name : Str,
	requires_ : Try(List(Str), [Missing]),
	systems : Try(List(Str), [Missing]),
	sources : Try(List(Ir.Source), [Missing]),
	inputs : Try(List(Ir.Input), [Missing]),
	environments : Try(List(Ir.Environment), [Missing]),
	shells : Try(List(Ir.Shell), [Missing]),
	tasks : Try(List(Ir.Task), [Missing]),
	build_sources : Try(List(Ir.BuildSource), [Missing]),
	builds : Try(List(Ir.Build), [Missing]),
	workflows : Try(List(Ir.Workflow), [Missing]),
	extensions : Try(List(Ir.Extension), [Missing]),
	raw : Try(List(Ir.Raw), [Missing]),
}

# The empty project survives a wire round trip unchanged.
expect Ir.parse(Ir.empty("x").to_str()) == Ok(Ir.empty("x"))
# An older major is rejected by its header before its records are read.
expect
	Ir.parse("((format ((major 1) (minor 0))) (shells 42))")
		== Err(UnsupportedFormat({ major: 1, minor: 0 }))
# A newer major is rejected rather than guessed at.
expect
	Ir.parse("((format ((major 3) (minor 0))))")
		== Err(UnsupportedFormat({ major: 3, minor: 0 }))
# Earlier minor records omit newer optional build and workflow fields.
expect match Ir.parse("((format ((major 2) (minor 0))) (name \"x\"))") {
	Ok(ir) => ir.format == { major: 2, minor: 0 } and
		ir.build_sources.is_empty() and ir.builds.is_empty() and
			ir.workflows.is_empty()
	Err(_) => False
}
# The project name is required even when every list field is optional.
expect Ir.parse("((format ((major 2) (minor 0))))").is_err()
# The format header is required before any other field is interpreted.
expect Ir.parse("((name \"x\"))").is_err()
# A present build source must carry its required ref.
expect Ir.parse(
	\\((format ((major 2) (minor 1))) (name "x")
	\\ (build_sources (((name "assets")))))
	,
).is_err()
# A present build must carry its required output.
expect Ir.parse(
	\\((format ((major 2) (minor 1))) (name "x")
	\\ (builds (((name "app") (environment "dev") (inputs ()) (needs ())
	\\ (run ("true"))))))
	,
).is_err()
# Newer minors parse, leaving unknown required features for the consumer.
expect match Ir.parse(
	\\((format ((major 2) (minor 99))) (name "x")
	\\ (requires ("sources" "builds" "future")))
	,
) {
	Ok(ir) =>
		Ir.unsupported_features(ir, ["sources", "builds"]) == ["future"] and
			Ir.unsupported_features(ir, []) == ["sources", "builds", "future"]
	Err(_) => False
}
# Unknown optional fields are ignored at the top level and inside records.
expect match Ir.parse(
	\\((future (Tag 1)) (format ((major 2) (minor 99))) (name "x")
	\\ (shells (((name "s") (environment "dev") (future 1)))))
	,
) {
	Ok(ir) =>
		ir.format.minor == 99 and
			ir.shells == [{ name: "s", environment: "dev" }]
	Err(_) => False
}

# An older consumer must reject workflows via the required-feature marker.
expect match Ir.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (requires ("workflows")) (workflows (((name "ci") (steps ())))))
	,
) {
	Ok(ir) => ir.workflows == [{ name: "ci", steps: [] }] and
		Ir.unsupported_features(ir, ["sources", "builds"]) == ["workflows"]
	Err(_) => False
}

# Omitted workflow fields remain compatible with both earlier minor versions.
expect ["0", "1"].all(
	|minor|
		match Ir.parse("((format ((major 2) (minor ${minor}))) (name \"x\"))") {
			Ok(ir) => ir.workflows == []
			Err(_) => False
		},
)

# Unknown step tags cannot be silently dropped as optional top-level data.
expect Ir.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (workflows (((name "ci") (steps ((FutureStep "check")))))))
	,
).is_err()

# Task extra argv is required in every RunTask record on the wire.
expect Ir.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (workflows (((name "ci") (steps ((RunTask "check")))))))
	,
).is_err()

# A workflow must contain a typed steps list, even when intentionally empty.
expect Ir.parse(
	\\((format ((major 2) (minor 2))) (name "x")
	\\ (workflows (((name "ci")))))
	,
).is_err()
