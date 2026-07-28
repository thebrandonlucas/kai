import Blueprint
import Environment
import Requirement
import Target
import NixExpr

## Validates Nix-owned bindings and renders a complete development-shell flake.
##
## Portable requirements and environments remain in `blueprint`. This module
## supplies the concrete `nixpkgs` input and exact package path for every
## requirement on every declared target. It performs no effects and never
## invokes Nix.
Nix := [].{

	## A GitHub-backed flake input identified by owner, repository, and ref.
	##
	## The current renderer accepts exactly one input named `nixpkgs`. `owner`,
	## `repo`, and `ref` become `github:owner/repo/ref` in the generated flake.
	Input := { name : Str, owner : Str, repo : Str, ref : Str }

	## An exact mapping from a portable requirement to a Nix package path.
	##
	## `input` names the flake input that owns the package set. `path` contains
	## attribute segments below `legacyPackages.<system>`. An empty
	## `target_systems` list means every target declared by the workspace.
	Binding := {
		requirement : Requirement,
		target_systems : List(Target),
		input : Str,
		path : List(Str),
	}

	## All backend-owned data required to render a validated `Blueprint`.
	##
	## Environment structure and requirement order are intentionally absent: the
	## renderer reads them from the portable Blueprint.
	Config := { nixpkgs : Input, bindings : List(Binding) }

	## Structured Nix configuration failures returned by `render`.
	##
	## Errors accumulate in stable order: input metadata, bindings in declaration
	## order, missing or duplicate coverage in environment/target/requirement
	## order, then unused bindings.
	##
	## `BindingTargetNotDeclared(binding, requirement, target)` identifies a
	## zero-based binding index whose target is absent from the Blueprint.
	##
	## `DuplicateBinding(environment, requirement, target)` means more than one
	## binding applies to the same required tool.
	##
	## `DuplicateBindingTarget(binding, target)` identifies a target repeated in
	## one target-specific binding.
	##
	## `EmptyInputField(field)` names an empty `owner`, `repo`, or `ref` field.
	##
	## `EmptyPackagePath(binding, requirement)` identifies a binding with no
	## package path segments.
	##
	## `EmptyPackagePathSegment(binding, requirement, segment)` gives zero-based
	## binding and segment positions.
	##
	## `InvalidNixpkgsInputName(name)` reports an input not named `nixpkgs`.
	##
	## `MissingBinding(environment, requirement, target)` means no binding covers
	## one required tool.
	##
	## `UnknownInput(binding, requirement, input)` identifies a binding that does
	## not reference `nixpkgs`.
	##
	## `UnusedBinding(binding, requirement)` identifies configuration that cannot
	## apply to any declared environment and target.
	Error := [
		BindingTargetNotDeclared(U64, Str, Target),
		DuplicateBinding(Str, Str, Target),
		DuplicateBindingTarget(U64, Target),
		EmptyInputField(Str),
		EmptyPackagePath(U64, Str),
		EmptyPackagePathSegment(U64, Str, U64),
		InvalidNixpkgsInputName(Str),
		MissingBinding(Str, Str, Target),
		UnknownInput(U64, Str, Str),
		UnusedBinding(U64, Str),
	].{

		## Compares structured Nix configuration failures and their payloads.
		is_eq : Error, Error -> Bool
		is_eq = |left, right|
			match (left, right) {
				(BindingTargetNotDeclared(left_index, left_id, left_target), BindingTargetNotDeclared(right_index, right_id, right_target)) => left_index == right_index and left_id == right_id and left_target == right_target
				(DuplicateBinding(left_environment, left_id, left_target), DuplicateBinding(right_environment, right_id, right_target)) => left_environment == right_environment and left_id == right_id and left_target == right_target
				(DuplicateBindingTarget(left_index, left_target), DuplicateBindingTarget(right_index, right_target)) => left_index == right_index and left_target == right_target
				(EmptyInputField(left_field), EmptyInputField(right_field)) => left_field == right_field
				(EmptyPackagePath(left_index, left_id), EmptyPackagePath(right_index, right_id)) => left_index == right_index and left_id == right_id
				(EmptyPackagePathSegment(left_index, left_id, left_segment), EmptyPackagePathSegment(right_index, right_id, right_segment)) => left_index == right_index and left_id == right_id and left_segment == right_segment
				(InvalidNixpkgsInputName(left_name), InvalidNixpkgsInputName(right_name)) => left_name == right_name
				(MissingBinding(left_environment, left_id, left_target), MissingBinding(right_environment, right_id, right_target)) => left_environment == right_environment and left_id == right_id and left_target == right_target
				(UnknownInput(left_index, left_id, left_input), UnknownInput(right_index, right_id, right_input)) => left_index == right_index and left_id == right_id and left_input == right_input
				(UnusedBinding(left_index, left_id), UnusedBinding(right_index, right_id)) => left_index == right_index and left_id == right_id
				_ => Bool.False
			}
	}

	## Constructs GitHub input metadata without validating it.
	##
	## Arguments are the input name, GitHub owner, repository, and ref. Validation
	## occurs together with all bindings when `render` is called.
	github_input : Str, Str, Str, Str -> Input
	github_input = |name, owner, repo, ref| { name, owner, repo, ref }

	## Binds a requirement on every Blueprint target.
	##
	## The input name must currently be `nixpkgs`. Path segments are exact Nix
	## attribute names, such as `["rustc"]` or `["python3Packages", "ruff"]`.
	bind : Requirement, Str, List(Str) -> Binding
	bind = |requirement, input, path| { requirement, target_systems: [], input, path }

	## Binds a requirement only on the listed targets.
	##
	## Every listed target must be declared by the Blueprint. Duplicate targets
	## and overlapping applicable bindings are errors.
	bind_for : Requirement, List(Target), Str, List(Str) -> Binding
	bind_for = |requirement, target_systems, input, path| { requirement, target_systems, input, path }

	## Begins an unvalidated Nix configuration.
	##
	## The supplied binding order does not determine generated package order;
	## each environment's portable requirement order does.
	config : { nixpkgs : Input, bindings : List(Binding) } -> Config
	config = |fields| fields

	## Renders a complete flake, or returns all unambiguous backend errors.
	##
	## The result contains a generated-file notice and no trailing newline, so it
	## can be passed directly to a platform line-writing operation. Rendering is
	## deterministic for equal Blueprint and Config values. This function does
	## not read, create, or modify `flake.lock`.
	render : Blueprint, Config -> Try(Str, List(Error))
	render = |valid, config_value| {
		workspace = Blueprint.to_draft(valid)
		errors = validate_config(workspace, config_value)
		if errors.is_empty() {
			Ok(render_flake(workspace, config_value))
		} else {
			Err(errors)
		}
	}
}

validate_config : Blueprint.Draft, Nix.Config -> List(Nix.Error)
validate_config = |workspace, config_value| {
	input_errors = validate_input(config_value.nixpkgs)
	binding_errors = validate_bindings(config_value.bindings, workspace.target_systems, 0, input_errors)
	completeness_errors = validate_environments(workspace.envs, workspace.target_systems, config_value.bindings, binding_errors)
	validate_unused_bindings(config_value.bindings, workspace, 0, completeness_errors)
}

validate_input : Nix.Input -> List(Nix.Error)
validate_input = |input| {
	initial = if input.name == "nixpkgs" [] else [Nix.Error.InvalidNixpkgsInputName(input.name)]
	with_owner = if input.owner == "" initial.append(Nix.Error.EmptyInputField("owner")) else initial
	with_repo = if input.repo == "" with_owner.append(Nix.Error.EmptyInputField("repo")) else with_owner
	if input.ref == "" with_repo.append(Nix.Error.EmptyInputField("ref")) else with_repo
}

validate_bindings : List(Nix.Binding), List(Target), U64, List(Nix.Error) -> List(Nix.Error)
validate_bindings = |remaining, workspace_targets, index, errors|
	match remaining {
		[] => errors
		[binding, .. as rest] => {
			id = Requirement.id(binding.requirement)
			with_path = if binding.path.is_empty() errors.append(Nix.Error.EmptyPackagePath(index, id)) else validate_path_segments(binding.path, index, id, 0, errors)
			with_input = if binding.input == "nixpkgs" with_path else with_path.append(Nix.Error.UnknownInput(index, id, binding.input))
			with_targets = validate_binding_targets(binding.target_systems, workspace_targets, index, id, [], with_input)
			validate_bindings(rest, workspace_targets, index + 1, with_targets)
		}
	}

validate_path_segments : List(Str), U64, Str, U64, List(Nix.Error) -> List(Nix.Error)
validate_path_segments = |remaining, binding_index, requirement_id, segment_index, errors|
	match remaining {
		[] => errors
		[segment, .. as rest] => {
			next = if segment == "" errors.append(Nix.Error.EmptyPackagePathSegment(binding_index, requirement_id, segment_index)) else errors
			validate_path_segments(rest, binding_index, requirement_id, segment_index + 1, next)
		}
	}

validate_binding_targets : List(Target), List(Target), U64, Str, List(Target), List(Nix.Error) -> List(Nix.Error)
validate_binding_targets = |remaining, workspace_targets, binding_index, requirement_id, seen, errors|
	match remaining {
		[] => errors
		[target, .. as rest] => {
			with_duplicate = if seen.contains(target) errors.append(Nix.Error.DuplicateBindingTarget(binding_index, target)) else errors
			with_declared = if workspace_targets.contains(target) {
				with_duplicate
			} else {
				with_duplicate.append(Nix.Error.BindingTargetNotDeclared(binding_index, requirement_id, target))
			}
			validate_binding_targets(rest, workspace_targets, binding_index, requirement_id, seen.append(target), with_declared)
		}
	}

validate_environments : List(Environment), List(Target), List(Nix.Binding), List(Nix.Error) -> List(Nix.Error)
validate_environments = |remaining, declared_targets, bindings, errors|
	match remaining {
		[] => errors
		[environment, .. as rest] => {
			next = validate_environment_targets(environment, declared_targets, bindings, errors)
			validate_environments(rest, declared_targets, bindings, next)
		}
	}

validate_environment_targets : Environment, List(Target), List(Nix.Binding), List(Nix.Error) -> List(Nix.Error)
validate_environment_targets = |environment, remaining_targets, bindings, errors|
	match remaining_targets {
		[] => errors
		[target, .. as rest] => {
			next = validate_requirement_bindings(Environment.name(environment), environment.requirements, target, bindings, errors)
			validate_environment_targets(environment, rest, bindings, next)
		}
	}

validate_requirement_bindings : Str, List(Requirement), Target, List(Nix.Binding), List(Nix.Error) -> List(Nix.Error)
validate_requirement_bindings = |environment_name, remaining, target, bindings, errors|
	match remaining {
		[] => errors
		[requirement, .. as rest] => {
			id = Requirement.id(requirement)
			count = count_bindings(id, target, bindings, 0)
			next = if count == 0 {
				errors.append(Nix.Error.MissingBinding(environment_name, id, target))
			} else if count > 1 {
				errors.append(Nix.Error.DuplicateBinding(environment_name, id, target))
			} else {
				errors
			}
			validate_requirement_bindings(environment_name, rest, target, bindings, next)
		}
	}

count_bindings : Str, Target, List(Nix.Binding), U64 -> U64
count_bindings = |requirement_id, target, remaining, count|
	match remaining {
		[] => count
		[binding, .. as rest] => {
			matches_id = Requirement.id(binding.requirement) == requirement_id
			matches_target = binding.target_systems.is_empty() or binding.target_systems.contains(target)
			next = if matches_id and matches_target count + 1 else count
			count_bindings(requirement_id, target, rest, next)
		}
	}

validate_unused_bindings : List(Nix.Binding), Blueprint.Draft, U64, List(Nix.Error) -> List(Nix.Error)
validate_unused_bindings = |remaining, workspace, index, errors|
	match remaining {
		[] => errors
		[binding, .. as rest] => {
			id = Requirement.id(binding.requirement)
			used = binding_is_used(binding, workspace.envs, workspace.target_systems)
			next = if used errors else errors.append(Nix.Error.UnusedBinding(index, id))
			validate_unused_bindings(rest, workspace, index + 1, next)
		}
	}

binding_is_used : Nix.Binding, List(Environment), List(Target) -> Bool
binding_is_used = |binding, environments, declared_targets| {
	id = Requirement.id(binding.requirement)
	requirement_used = environments.any(|environment| environment.requirements.any(|requirement| Requirement.id(requirement) == id))
	target_used = binding.target_systems.is_empty() or binding.target_systems.any(|target| declared_targets.contains(target))
	requirement_used and target_used
}

render_flake : Blueprint.Draft, Nix.Config -> Str
render_flake = |workspace, config_value| {
	input = config_value.nixpkgs
	flake = NixExpr.AttrSet([
		{ name: "description", value: NixExpr.String("Development environments for ${workspace.name}") },
		{
			name: "inputs",
			value: NixExpr.AttrSet([
				{
					name: "nixpkgs",
					value: NixExpr.AttrSet([
						{ name: "url", value: NixExpr.String("github:${input.owner}/${input.repo}/${input.ref}") },
					]),
				},
			]),
		},
		{
			name: "outputs",
			value: NixExpr.Lambda(
				["nixpkgs"],
				NixExpr.AttrSet([
					{ name: "devShells", value: render_dev_shells(workspace, config_value.bindings) },
				]),
			),
		},
	])
	"# Generated by roc-blueprint and roc-blueprint-nix. Do not edit.\n${NixExpr.format(flake)}"
}

render_dev_shells : Blueprint.Draft, List(Nix.Binding) -> NixExpr
render_dev_shells = |workspace, bindings|
	NixExpr.AttrSet(
		workspace.target_systems.map(
			|target| {
				name: Target.to_str(target),
				value: NixExpr.AttrSet(
					workspace.envs.map(
						|environment| {
							name: Environment.name(environment),
							value: render_environment(environment, target, bindings),
						},
					),
				),
			},
		),
	)

render_environment : Environment, Target, List(Nix.Binding) -> NixExpr
render_environment = |environment, target, bindings| {
	target_name = Target.to_str(target)
	package_exprs = environment.requirements.map(
		|requirement| {
			binding = find_binding(Requirement.id(requirement), target, bindings)
			NixExpr.Select(NixExpr.Identifier(binding.input), ["legacyPackages", target_name].concat(binding.path))
		},
	)
	mk_shell = NixExpr.Select(NixExpr.Identifier("nixpkgs"), ["legacyPackages", target_name, "mkShell"])
	NixExpr.Apply(mk_shell, NixExpr.AttrSet([{ name: "packages", value: NixExpr.ListExpr(package_exprs) }]))
}

find_binding : Str, Target, List(Nix.Binding) -> Nix.Binding
find_binding = |requirement_id, target, bindings|
	match bindings {
		[] => {
			crash "validated binding disappeared during lowering"
		}
		[binding, .. as rest] => {
			matches_id = Requirement.id(binding.requirement) == requirement_id
			matches_target = binding.target_systems.is_empty() or binding.target_systems.contains(target)
			if matches_id and matches_target binding else find_binding(requirement_id, target, rest)
		}
	}

rust : Requirement
rust = Requirement.new({ id: "rust-compiler", display_name: "Rust compiler" })

git : Requirement
git = Requirement.new({ id: "git", display_name: "Git" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace({
	name: "example",
	target_systems: [Target.X86_64Linux],
	envs: [Environment.new({ name: "default", requirements: [rust] })],
})

nixpkgs : Nix.Input
nixpkgs = Nix.github_input("nixpkgs", "NixOS", "nixpkgs", "nixos-unstable")

## Missing requirement bindings return a structured error instead of source.
expect {
	valid = Blueprint.validate(workspace)?
	Nix.render(valid, Nix.config({ nixpkgs, bindings: [] })) == Err([
		Nix.Error.MissingBinding("default", "rust-compiler", Target.X86_64Linux),
	])
}

## Duplicate and unused bindings accumulate in stable order.
expect {
	valid = Blueprint.validate(workspace)?
	Nix.render(
		valid,
		Nix.config({
			nixpkgs,
			bindings: [
				Nix.bind(rust, "nixpkgs", ["rustc"]),
				Nix.bind(rust, "nixpkgs", ["cargo"]),
				Nix.bind(git, "nixpkgs", ["git"]),
			],
		}),
	) == Err([
		Nix.Error.DuplicateBinding("default", "rust-compiler", Target.X86_64Linux),
		Nix.Error.UnusedBinding(2, "git"),
	])
}

## Bindings for undeclared targets are rejected and remain unused.
expect {
	valid = Blueprint.validate(workspace)?
	Nix.render(
		valid,
		Nix.config({
			nixpkgs,
			bindings: [Nix.bind_for(rust, [Target.Aarch64Linux], "nixpkgs", ["rustc"])],
		}),
	) == Err([
		Nix.Error.BindingTargetNotDeclared(0, "rust-compiler", Target.Aarch64Linux),
		Nix.Error.MissingBinding("default", "rust-compiler", Target.X86_64Linux),
		Nix.Error.UnusedBinding(0, "rust-compiler"),
	])
}

## Invalid input metadata is reported before binding-completeness errors.
expect {
	valid = Blueprint.validate(workspace)?
	invalid_input = Nix.github_input("pkgs", "", "", "")
	Nix.render(
		valid,
		Nix.config({
			nixpkgs: invalid_input,
			bindings: [Nix.bind(rust, "nixpkgs", ["rustc"])],
		}),
	) == Err([
		Nix.Error.InvalidNixpkgsInputName("pkgs"),
		Nix.Error.EmptyInputField("owner"),
		Nix.Error.EmptyInputField("repo"),
		Nix.Error.EmptyInputField("ref"),
	])
}

## Empty package path segments and unknown inputs are structured errors.
expect {
	valid = Blueprint.validate(workspace)?
	Nix.render(
		valid,
		Nix.config({
			nixpkgs,
			bindings: [Nix.bind(rust, "other", ["", "rustc"])],
		}),
	) == Err([
		Nix.Error.EmptyPackagePathSegment(0, "rust-compiler", 0),
		Nix.Error.UnknownInput(0, "rust-compiler", "other"),
	])
}

## Binding declaration order does not affect generated source.
expect {
	two_requirement_workspace = Blueprint.workspace({
		name: "ordering",
		target_systems: [Target.X86_64Linux],
		envs: [Environment.new({ name: "default", requirements: [rust, git] })],
	})
	valid = Blueprint.validate(two_requirement_workspace)?
	first = Nix.render(
		valid,
		Nix.config({
			nixpkgs,
			bindings: [Nix.bind(rust, "nixpkgs", ["rustc"]), Nix.bind(git, "nixpkgs", ["git"])],
		}),
	)?
	second = Nix.render(
		valid,
		Nix.config({
			nixpkgs,
			bindings: [Nix.bind(git, "nixpkgs", ["git"]), Nix.bind(rust, "nixpkgs", ["rustc"])],
		}),
	)?
	first == second
}
