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
	CommandChange := [
		Add(Command.Implementation),
		Replace(Command.Implementation),
	]

	Config : {
		name : Str,
		shell : {
			pkgs : List(Str),
		},
		commands : List(CommandChange),
	}

	render : Config -> Try(
		Str,
		[
			BlueprintInvalid(List(Blueprint.Error)),
			NixInvalid(List(Nix.Error)),
		],
	)
	render = |config| render_source(config)

	registry : Config -> Try(Command.Registry, Command.RegistryError)
	registry = |config| {
		standard = Command.add(
			Command.empty_registry,
			default_nix_shell(config),
		)?

		apply_command_changes(config.commands, standard)
	}

	default_nix_shell : Config -> Command.Implementation
	default_nix_shell = |config| {
		command: "shell",
		contract: "kai.shell.v1",
		id: "kai.shell.default.nix",
		backends: [Command.Backend.Nix],
		handler: |_request| {
			match render_source(config) {
				Err(error) =>
					Err(Command.Error.PlanningFailed(Str.inspect(error)))
				Ok(source) =>
					Ok({
						files: [
							{
								path: ".kai/flake.nix",
								contents: source,
							},
						],
						argv: ["nix", "develop", "path:.kai#default"],
					})
				}
		},
	}
}

apply_command_changes : List(Kai.CommandChange),
Command.Registry -> Try(
	Command.Registry,
	Command.RegistryError,
)
apply_command_changes = |changes, registry|
	match changes {
		[] => Ok(registry)
		[Kai.CommandChange.Add(implementation), .. as rest] => {
			updated = Command.add(registry, implementation)?
			apply_command_changes(rest, updated)
		}
		[Kai.CommandChange.Replace(implementation), .. as rest] => {
			updated = Command.replace(registry, implementation)?
			apply_command_changes(rest, updated)
		}
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

test_config : Str, List(Str) -> Kai.Config
test_config = |name, pkgs|
	test_config_with_commands(name, pkgs, [])

test_config_with_commands : Str, List(Str), List(Kai.CommandChange) -> Kai.Config
test_config_with_commands = |name, pkgs, commands| {
	name,
	shell: { pkgs: pkgs },
	commands,
}

render_for_test = |name, pkgs|
	Kai.render(test_config(name, pkgs))

chunk_three_config : Kai.Config
chunk_three_config = test_config(
	"chunk three",
	["git", "git", "curl"],
)

chunk_three_request : Command.Request
chunk_three_request = {
	project: "chunk three",
	backend: Command.Backend.Nix,
	args: [],
}

## Duplicate package declarations should produce the same
## output as their deduplicated form.
expect {
	with_duplicates = render_for_test(
		"example",
		["git", "git", "curl"],
	)
	without_duplicates = render_for_test(
		"example",
		["git", "curl"],
	)

	with_duplicates == without_duplicates
}

## An empty workspace name produces a structured
## Blueprint validation error.
expect render_for_test("", ["git"]) == Err(
	BlueprintInvalid([
		Blueprint.Error.EmptyWorkspaceName,
	]),
)

## An empty package identity identifies the containing environment
expect render_for_test("example", [""]) == Err(
	BlueprintInvalid([
		Blueprint.Error.EmptyRequirementId("default"),
	]),
)

## The default implementation has stable registry-facing identity.
expect {
	implementation = Kai.default_nix_shell(chunk_three_config)

	exact_backends = match implementation.backends {
		[Command.Backend.Nix] => Bool.True
		_ => Bool.False
	}

	implementation.command == "shell"
		and implementation.contract == "kai.shell.v1"
			and implementation.id == "kai.shell.default.nix"
				and exact_backends
}

## The default implementation satisfies the generic command contract.
expect {
	implementation = Kai.default_nix_shell(chunk_three_config)

	match Command.validate_implementation(implementation) {
		Ok({}) => Bool.True
		Err(_) => Bool.False
	}
}

## The planned file path and independently frozen source are exact.
expect {
	implementation = Kai.default_nix_shell(chunk_three_config)
	handler = implementation.handler
	plan = handler(chunk_three_request)?

	expected_source = "# Generated by roc-blueprint and roc-blueprint-nix. Do not edit.\n{\n  \"description\" = \"Development environments for chunk three\";\n  \"inputs\" = {\n    \"nixpkgs\" = {\n      \"url\" = \"github:NixOS/nixpkgs/nixos-unstable\";\n    };\n  };\n  \"outputs\" = { nixpkgs, ... }:\n    {\n      \"devShells\" = {\n        \"x86_64-linux\" = {\n          \"default\" = nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"mkShell\" {\n            \"packages\" = [\n              nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"git\"\n              nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"curl\"\n            ];\n          };\n        };\n      };\n    };\n}"

	plan.files == [
		{
			path: ".kai/flake.nix",
			contents: expected_source,
		},
	]
}

## The planned argv preserves argument boundaries and ordering.
expect {
	implementation = Kai.default_nix_shell(chunk_three_config)
	handler = implementation.handler
	plan = handler(chunk_three_request)?

	plan.argv == ["nix", "develop", "path:.kai#default"]
}

## The default handler produces a valid generic command plan.
expect {
	implementation = Kai.default_nix_shell(chunk_three_config)
	handler = implementation.handler
	plan = handler(chunk_three_request)?

	match Command.validate_plan(plan) {
		Ok({}) => Bool.True
		Err(_) => Bool.False
	}
}

## add fixtures and tests for registry
