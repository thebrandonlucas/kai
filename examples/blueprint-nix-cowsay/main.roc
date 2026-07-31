## Showcase usage of "blueprint" adapted from
## [roc-blueprint](https://github.com/lukewilliamboswell/roc-blueprint)
app [main!] {
	pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst",
	blueprint: "../../platform/blueprint/package.roc",
}

import pf.Stdout
import blueprint.Blueprint
import blueprint.Requirement
import blueprint.Target
import blueprint.Environment
import blueprint.Nix

# A Requirement is a generic term for
# a piece of software the shell requires
# and that the blueprint will validate.
cowsay : Requirement
cowsay = Requirement.new({
	id: "cowsay",
	display_name: "Cowsay",
})

# Create a Draft Blueprint of what the eventual shell
# will look like.
#
# Structs used here:
# - Blueprint: Top level definition
workspace : Blueprint.Draft
workspace = Blueprint.workspace({
	name: "cowsay shell",
	target_systems: [Target.X86_64Linux],
	envs: [
		Environment.new({
			name: "default",
			requirements: [cowsay],
		}),
	],
})

nix_config : Nix.Config
nix_config = Nix.config({
	nixpkgs: Nix.github_input(
		"nixpkgs",
		"NixOS",
		"nixpkgs",
		"nixos-unstable",
	),
	bindings: [
		Nix.bind(
			cowsay,
			"nixpkgs",
			["cowsay"],
		),
	],
})

main! : List(Str) => Try({}, _)
main! = |_args| {
	valid = Blueprint.validate(workspace) ? |errors| BlueprintInvalid(errors)
	source = Nix.render(valid, nix_config) ? |errors| NixInvalid(errors)
	Stdout.line!(source)?
	Ok({})
}
