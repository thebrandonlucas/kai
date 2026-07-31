## Define functions to be consumed by the app.
##
##
import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target
import blueprint.Nix

import Command

# Friendly Kai configuration and its pure lowering pipeline.
Kai := [].{
	Config : {
		name : Str,
		shell : {
			pkgs : List(Str),
		},
	}

	render : Config -> Try(
		Str,
		[
			BlueprintInvalid(List(Blueprint.Error)),
			NixInvalid(List(Nix.Error)),
		],
	)
	render = |config| render_source(config)
}

render_source : Kai.Config -> Try(
	Str,
	[
		BlueprintInvalid(List(Blueprint.Error)),
		NixInvalid(List(Nix.Error)),
	],
)
render_source = |config| {
	unique_pkgs = unique_strings(config.shell.pkgs, [])

	requirements = unique_pkgs.map(
		|pkg|
			Requirement.new({ id: pkg, display_name: pkg }),
	)

	workspace = Blueprint.workspace({
		name: config.name,
		target_systems: [Target.X86_64Linux],
		envs: [
			Environment.new({ name: "default", requirements }),
		],
	})

	valid = Blueprint.validate(workspace)
		? |errors| BlueprintInvalid(errors)

	bindings = requirements.map(
		|requirement|
			Nix.bind(
				requirement,
				"nixpkgs",
				Str.split_on(
					Requirement.id(requirement),
					".",
				),
			),
	)

	nix_config = Nix.config({
		nixpkgs: Nix.github_input(
			"nixpkgs",
			"NixOS",
			"nixpkgs",
			"nixos-unstable",
		),
		bindings,
	})

	source = Nix.render(valid, nix_config)
		? |errors| NixInvalid(errors)

	Ok(source)
}

unique_strings : List(Str), List(Str) -> List(Str)
unique_strings = |remaining, seen|
	match remaining {
		[] => seen
		[first, .. as rest] =>
			if seen.contains(first) {
				unique_strings(rest, seen)
			} else {
				unique_strings(rest, seen.append(first))
			}
		}

## -- TESTS --

## Duplicate package declarations should produce the same
## output as their deduplicated form.
expect {
	with_duplicates = Kai.render({
		name: "example",
		shell: {
			pkgs: ["git", "git", "curl"],
		},
	})

	without_duplicates = Kai.render({
		name: "example",
		shell: {
			pkgs: ["git", "curl"],
		},
	})

	with_duplicates == without_duplicates
}

## An empty workspace name produces a structured
## Blueprint validation error.
expect Kai.render({
	name: "",
	shell: { pkgs: ["git"] },
}) == Err(
	BlueprintInvalid([
		Blueprint.Error.EmptyWorkspaceName,
	]),
)

## An empty package identity identifies the containing environment
expect Kai.render({
	name: "example",
	shell: {
		pkgs: [""],
	},
}) == Err(
	BlueprintInvalid([
		Blueprint.Error.EmptyRequirementId("default"),
	]),
)
