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
	inputs : List({ name : Str, url : Str, kind : [Overlay, Flake] }),
	environments : List(
		{
			name : Str,
			parents : List(Str),
			tools : List({ source : Str, name : Str }),
			overlays : List(Str),
			env : List({ name : Str, value : Str }),
			pure : Bool,
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
	Input : { name : Str, url : Str, kind : [Overlay, Flake] }
	Tool : { source : Str, name : Str }
	Environment : {
		name : Str,
		parents : List(Str),
		tools : List(Tool),
		overlays : List(Str),
		env : List(Variable),
		pure : Bool,
	}

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
	current_format = { major: 2, minor: 4 }

	empty : Str -> Model
	empty = |name| Model.{
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
