import Blueprint
import Requirement
import Target
import Environment
import Nix

# map simple config in kai.roc to it's equivalent blueprint
# does config need to hold values?
# yes
# opaque? no, blueprint needs to read it?
# Create a config with a bunch of default assumptions into a blueprint
## This is doc
Config := {
	shell : {
		requirements : List(Requirement),
	},
}.{

	# get_requirements : Config -> List(Requirement)
	# get_requirements = |config| {
	# 	requirements = config.shell.requirements.map(
	# 		|pkg|
	# 			Requirement.new({
	# 				id: pkg,
	# 				display_name: pkg,
	# 			}),
	# 	)
	#
	# 	requirements
	# }

	to_draft : Config -> Blueprint.Draft
	to_draft = |config| {

		Blueprint.workspace({
			name: "todo-workspace",
			target_systems: [Target.X86_64Linux],
			envs: [
				Environment.new(
					{ name: "todo-env", requirements: config.shell.requirements },
				),
			],
		})
	}

	# 

	# validate the blueprint and bind to backend
	validate : Config -> Try(Blueprint, [BlueprintInvalid(List(Blueprint.Error))])
	validate = |config| {
		valid = Blueprint.validate(to_draft(config)) ? |errors| BlueprintInvalid(errors)
		Ok(valid)
	}

	# bind blueprint to the backend and return the source output
	bind : Blueprint -> Try(Str, [NixInvalid(List(Nix.Error))])
	bind = |blueprint| {

		# what if there's multiple envs?

		view = Blueprint.view(blueprint)
		all_requirements = view.envs.fold([], |acc, environment| acc.concat(environment.requirements))
		# Need to dedupe while preserving declaration order
		unique_requirements = all_requirements.fold(
			[],
			|unique, requirement| {
				already_present = unique.any(|existing|

					Requirement.id(existing) == Requirement.id(requirement))

				if already_present {
					unique
				} else {
					unique.append(requirement)
				}
			},
		)
		# FIXME: decouple from Nix, but also third arg is a nix attr path for this requirement 
		# Think pythonPackages.python3 for python. for now we assume path == nix name direct

		bindings = unique_requirements.map(
			|requirement|

				Nix.bind(
					requirement,
					"nixpkgs",
					[
						Requirement.id(requirement),
					],
				),
		)

		# create the blueprint's backend binding
		# FIXME: variablize this comes from the "environment" ro the .kai 
		# basically, backend must be managed by the kai cli tool from available
		# backends on machine
		# TODO: rename to "binding" as more acc term
		nix_binding : Nix.Config
		nix_binding = Nix.config({
			# TODO: make defaults which are overrideable <somewhere>
			# Perhaps blueprint is the place to override them
			nixpkgs: Nix.github_input("nixpkgs", "NixOS", "nixpkgs", "nixos-unstable"),
			bindings,
		})

		source = Nix.render(blueprint, nix_binding) ? |errors| NixInvalid(errors)

		Ok(source)
	}

	# return the string to write to flake.nix
	make : Config -> Try(
		Str,
		[BlueprintInvalid(List(Blueprint.Error)), NixInvalid(List(Nix.Error)), ..],
	)
	make = |config| {
		blueprint = validate(config)?
		source = bind(blueprint)?

		Ok(source)

	}
}
