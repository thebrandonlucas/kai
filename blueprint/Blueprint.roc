import Environment
import Requirement
import Target

## A validated, backend-neutral development workspace.
##
## A `Blueprint` contains a workspace name, its supported target systems, and
## its named development environments. It is opaque: applications construct a
## `Draft` and must pass `validate` before a backend can consume the result.
## This prevents renderers from accidentally accepting unchecked data.
##
## ```roc
## git = Requirement.new({ id: "git", display_name: "Git" })
## draft = Blueprint.workspace(
## 	{
## 		name: "example",
## 		target_systems: [Target.X86_64Linux],
## 		envs: [Environment.new({ name: "default", requirements: [git] })],
## 	},
## )
## validated = Blueprint.validate(draft)
## ```
Blueprint :: {
	name : Str,
	target_systems : List(Target),
	envs : List(Environment),
}.{

	## Compares validated workspaces by all portable fields.
	is_eq : Blueprint, Blueprint -> Bool
	is_eq = |left, right|
		left.name == right.name and left.target_systems == right.target_systems and left.envs == right.envs

	## Unvalidated input for `workspace` and `validate`.
	##
	## `name` identifies the workspace. `target_systems` declares every system
	## for which its environments are defined. `envs` retains declaration order,
	## as do the requirements inside each environment.
	Draft := {
		name : Str,
		target_systems : List(Target),
		envs : List(Environment),
	}.{

		## Compares draft workspaces by all portable fields.
		is_eq : Draft, Draft -> Bool
		is_eq = |left, right|
			left.name == right.name and left.target_systems == right.target_systems and left.envs == right.envs
	}

	## Portable validation failures returned by `validate`.
	##
	## Errors accumulate in stable validation and declaration order:
	##
	## `ConflictingRequirement(id)` means the same requirement identity has
	## different display names across environments.
	##
	## `DuplicateEnvironment(name)` identifies a repeated environment name.
	##
	## `DuplicateRequirement(environment, id)` identifies a requirement used
	## more than once in one environment.
	##
	## `DuplicateTarget(target)` identifies a repeated workspace target.
	##
	## `EmptyEnvironmentName(index)` gives the zero-based position of an
	## environment with an empty name.
	##
	## `EmptyEnvironments` means the workspace declares no environments.
	##
	## `EmptyRequirementId(environment)` identifies the containing environment.
	##
	## `EmptyTargets` means the workspace declares no target systems.
	##
	## `EmptyWorkspaceName` means the workspace name is empty.
	Error := [
		ConflictingRequirement(Str),
		DuplicateEnvironment(Str),
		DuplicateRequirement(Str, Str),
		DuplicateTarget(Target),
		EmptyEnvironmentName(U64),
		EmptyEnvironments,
		EmptyRequirementId(Str),
		EmptyTargets,
		EmptyWorkspaceName,
	].{

		## Compares structured validation failures and their payloads.
		is_eq : Error, Error -> Bool
		is_eq = |left, right|
			match (left, right) {
				(ConflictingRequirement(left_id), ConflictingRequirement(right_id)) => left_id == right_id
				(DuplicateEnvironment(left_name), DuplicateEnvironment(right_name)) => left_name == right_name
				(DuplicateRequirement(left_environment, left_id), DuplicateRequirement(right_environment, right_id)) => left_environment == right_environment and left_id == right_id
				(DuplicateTarget(left_target), DuplicateTarget(right_target)) => left_target == right_target
				(EmptyEnvironmentName(left_index), EmptyEnvironmentName(right_index)) => left_index == right_index
				(EmptyEnvironments, EmptyEnvironments) => Bool.True
				(EmptyRequirementId(left_environment), EmptyRequirementId(right_environment)) => left_environment == right_environment
				(EmptyTargets, EmptyTargets) => Bool.True
				(EmptyWorkspaceName, EmptyWorkspaceName) => Bool.True
				_ => Bool.False
			}
	}

	## Begins a workspace description without validating it.
	##
	## This constructor intentionally preserves the supplied data exactly. Call
	## `validate` after composing the complete draft.
	workspace : Draft -> Draft
	workspace = |fields| fields

	## Validates a complete draft and seals it as an opaque `Blueprint`.
	##
	## Returns every independent error that can be reported without inventing
	## replacement data. Successful validation preserves all declared list order.
	validate : Draft -> Try(Blueprint, List(Error))
	validate = |workspace_draft| {
		initial = if workspace_draft.name == "" [EmptyWorkspaceName] else []
		with_targets = if workspace_draft.target_systems.is_empty() initial.append(EmptyTargets) else initial
		with_target_duplicates = validate_targets(workspace_draft.target_systems, [], with_targets)
		with_environments = if workspace_draft.envs.is_empty() with_target_duplicates.append(EmptyEnvironments) else with_target_duplicates
		errors = validate_environments(workspace_draft.envs, 0, [], [], with_environments)

		if errors.is_empty() {
			Ok(
				Blueprint.{
					name: workspace_draft.name,
					target_systems: workspace_draft.target_systems,
					envs: workspace_draft.envs,
				},
			)
		} else {
			Err(errors)
		}
	}

	## Exposes validated portable data for inspection by backend packages.
	##
	## The returned record is equal to the draft that produced the `Blueprint`.
	## Changing it does not change the already validated value; validate the new
	## draft again before rendering it.
	to_draft : Blueprint -> Draft
	to_draft = |blueprint| {
		name: blueprint.name,
		target_systems: blueprint.target_systems,
		envs: blueprint.envs,
	}

	## Read the values. As opposed to to_draft which tends to modify them
	View := { name : Str, target_systems : List(Target), envs : List(Environment) }

	view : Blueprint -> View
	view = |blueprint| {
		View.{
			name: blueprint.name,
			target_systems: blueprint.target_systems,
			envs: blueprint.envs,
		}
	}
}

validate_targets : List(Target), List(Target), List(Blueprint.Error) -> List(Blueprint.Error)
validate_targets = |remaining, seen, errors|
	match remaining {
		[] => errors
		[target, .. as rest] =>
			if seen.contains(target) {
				validate_targets(rest, seen, errors.append(Blueprint.Error.DuplicateTarget(target)))
			} else {
				validate_targets(rest, seen.append(target), errors)
			}
		}

validate_environments : List(Environment), U64, List(Str), List(Requirement), List(Blueprint.Error) -> List(Blueprint.Error)
validate_environments = |remaining, index, seen_names, seen_requirements, errors|
	match remaining {
		[] => errors
		[environment, .. as rest] => {
			name = Environment.name(environment)
			with_name = if name == "" {
				errors.append(Blueprint.Error.EmptyEnvironmentName(index))
			} else if seen_names.contains(name) {
				errors.append(Blueprint.Error.DuplicateEnvironment(name))
			} else {
				errors
			}

			with_requirements = validate_environment_requirements(name, environment.requirements, [], seen_requirements, with_name)
			next_seen_requirements = append_new_requirements(environment.requirements, seen_requirements)
			next_names = if name == "" seen_names else seen_names.append(name)

			validate_environments(rest, index + 1, next_names, next_seen_requirements, with_requirements)
		}
	}

validate_environment_requirements : Str, List(Requirement), List(Str), List(Requirement), List(Blueprint.Error) -> List(Blueprint.Error)
validate_environment_requirements = |environment_name, remaining, local_ids, global_requirements, errors|
	match remaining {
		[] => errors
		[requirement, .. as rest] => {
			id = Requirement.id(requirement)
			display_name = Requirement.display_name(requirement)
			with_empty = if id == "" errors.append(Blueprint.Error.EmptyRequirementId(environment_name)) else errors
			with_duplicate = if local_ids.contains(id) {
				with_empty.append(Blueprint.Error.DuplicateRequirement(environment_name, id))
			} else {
				with_empty
			}
			with_conflict = match find_requirement(id, global_requirements) {
				Some(previous) if Requirement.display_name(previous) != display_name => with_duplicate.append(Blueprint.Error.ConflictingRequirement(id))
				_ => with_duplicate
			}

			validate_environment_requirements(environment_name, rest, local_ids.append(id), global_requirements, with_conflict)
		}
	}

append_new_requirements : List(Requirement), List(Requirement) -> List(Requirement)
append_new_requirements = |remaining, accumulated|
	match remaining {
		[] => accumulated
		[requirement, .. as rest] => {
			id = Requirement.id(requirement)
			next = match find_requirement(id, accumulated) {
				Some(_) => accumulated
				None => accumulated.append(requirement)
			}
			append_new_requirements(rest, next)
		}
	}

find_requirement : Str, List(Requirement) -> [None, Some(Requirement)]
find_requirement = |id, requirements|
	match requirements {
		[] => None
		[requirement, .. as rest] =>
			if Requirement.id(requirement) == id Some(requirement) else find_requirement(id, rest)
		}

rust : Requirement
rust = Requirement.new({ id: "rust-compiler", display_name: "Rust compiler" })

valid_workspace : Blueprint.Draft
valid_workspace = Blueprint.workspace({
	name: "example",
	target_systems: [Target.X86_64Linux],
	envs: [Environment.new({ name: "default", requirements: [rust] })],
})

## A valid draft is sealed and remains inspectable by backend packages.
expect {
	valid = Blueprint.validate(valid_workspace)?
	Blueprint.to_draft(valid) == valid_workspace
}

## Empty required workspace collections produce stable declaration-order errors.
expect Blueprint.validate(Blueprint.workspace({ name: "", target_systems: [], envs: [] })) == Err([
	Blueprint.Error.EmptyWorkspaceName,
	Blueprint.Error.EmptyTargets,
	Blueprint.Error.EmptyEnvironments,
])

## Independent duplicate errors accumulate in target, requirement, then environment order.
expect {
	invalid = Blueprint.workspace({
		name: "duplicates",
		target_systems: [Target.X86_64Linux, Target.X86_64Linux],
		envs: [
			Environment.new({ name: "dev", requirements: [rust, rust] }),
			Environment.new({ name: "dev", requirements: [] }),
		],
	})
	Blueprint.validate(invalid) == Err([
		Blueprint.Error.DuplicateTarget(Target.X86_64Linux),
		Blueprint.Error.DuplicateRequirement("dev", "rust-compiler"),
		Blueprint.Error.DuplicateEnvironment("dev"),
	])
}

## Invalid identities and conflicting declarations accumulate without invented replacements.
expect {
	empty_id = Requirement.new({ id: "", display_name: "Missing identity" })
	conflicting_rust = Requirement.new({ id: "rust-compiler", display_name: "Different display name" })
	invalid = Blueprint.workspace({
		name: "identity-errors",
		target_systems: [Target.X86_64Linux],
		envs: [
			Environment.new({ name: "", requirements: [empty_id] }),
			Environment.new({ name: "one", requirements: [rust] }),
			Environment.new({ name: "two", requirements: [conflicting_rust] }),
		],
	})
	Blueprint.validate(invalid) == Err([
		Blueprint.Error.EmptyEnvironmentName(0),
		Blueprint.Error.EmptyRequirementId(""),
		Blueprint.Error.ConflictingRequirement("rust-compiler"),
	])
}
