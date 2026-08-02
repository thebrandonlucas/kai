# Friendly Kai configuration and its pure lowering pipeline.
Kai := [].{
	Config : {
		shell : {
			pkgs : List(Str),
		},
	}

	render : Config -> Try(
		Str,
		[InvalidConfig],
	)
	render = |config| {
		_valid = validate(config)?
		Ok("im a flake")
	}

	# TODO: add specific validation errors as validation rules are introduced.
	validate : Config -> Try(Config, [InvalidConfig])
	validate = |config|
		Ok(config)
	# after validating, we need to choose how to render it 
	#     the actual logic of rendering shouldn't live here, 
	#     but in dedicated modules which define what rendering means
	#     for a given backend.
	#
	#       There are multiple variables to think about: 
	#
	#       - For a given _backend_ and _command_, we look for whether 
	#         that backend/command combo is registered. If it is registered,
	#         then we execute the corresponding function to generate the string,
	#         this high level renderer should just look for the backend, receive
	#         the render string after validating config, then hand it off
	#         to the CLI as the return from render()

	# How do we determine whether something is registered? Via compile-time 
	# and plugin checks like Caddy. We can start by creating the standard module,
	# which we will use as the testbed.

	# standard module will be .kai/standard.kai.module.roc, and we will 
	# build it into the binary at compile time? this will prove that we can do it 
	# for others

	# Generically turn it into the backend string of choice.
	# For Nix, this is a flake.nix.
	# For Guix, this is a future backend format.

	# steps:
	# get selected backend
	# for that backend, check 

	# Now I'm realizing the built-in assumption: we always assume 
	# the command is shell! that's what rende

	# Ok, so the necessary interlocking pieces are: 
	# - cli.roc, performs effects as scoped by Cli.roc,
	# - Kai.roc, bridge between `kai.roc` and `cli.roc`
	# - cli.roc calls Kai.roc to get the pure data back from it 
	#   which tells it what to do for the given command. 
	#
	#   Right now, Kai _validates_ the data in kai.roc and 
	#   _renders_ data after it has been validated, but should it? 
	#   what can Kai really do after validating kai.roc, in a generic way?
	#
	#   In our current version, this works because shell directly just creates 
	#   a flake.nix, the source of which we can simply pass up to cli for it to 
	#   perform a write.
	#
	#   But what should we pass for build? What should we pass for deploy?
	#
	#   On the one hand, I suppose for each of these we could have some file 
	#   to be written which justifies the source. for build it would just be a 
	#   modified flake.nix with a build step. but for deploy, which can be highly variable,
	#   and doesn't necessarily produce an artifact but rather performs an effect?
	#
	#   but then wait a minute, kai.roc is a config file. therefore anything in 
	#   kai.roc should be config that maps down into the corresponding management file 
	#   i.e. flake.nix? and anything that isn't has it's logic separately managed?
	#
	#   Or, maybe rather,
	#
	#   The only requirement is that Kai.roc is the pure boundary between pure kai.roc
	#   config and effectful kai cli.
	#
	#   This means it's responsibilities are: 
	#   1. validating config 
	#   2. doing as much pure logical work as it can before passing result
	#      back to CLI. This is also where tests should happen because pure.
	#   3. pass result and/or tell cli! next effectful thing to do.
	#
	#   In the case of shell, this is easy: validate config, create shell source
	#   flake.nix, send that back with a "write this file and enter the shell" signal.
	#
	#   In the case of build, this is easy, create shell source (could be 
	#   coupled with shell), return flake.nix, the cli writes it.
	#
	#   The only thing I'm really sure of is that Kai.roc should validate config 
	#   This means it should take the contract (from outside), validate it, and pass
	#   it back to cli for next decision.

	# However it is clear that Kai.roc (boundary between kai.roc and cli.roc) and cli.roc 
	# (boundary between kai operations and side-effects on device) will be thin wrappers
	# around a module system which will define: 
	#
	# 1. Command: This is the deterministic protocol level command shape
	#   - name: 
	#   - input: 
	#     - must specify type signature for each command
	#   - output:
	#     - must specify exact shape of output and validate
	#
	# 2. Backend:
	#   - name
	#   - package source (name (nixpkgs) and/or url)
	#   - commands (available): e.g. can this backend do 
	#               shell and build? what about deploy (no)?
	#               The command must implement everything from 
	#               Command.
	# 3. Implementation: Actual implementation of a Command for a Backend.
	#                    Must conform to specified Command shape
	#   - handler: Actual code to run the backend
	#   - backend: Compatible backend

	# Since we can't know in advance what files will be needed,
	# the registry must be generated first by roc, into a file 
	# which has all the imports needed in the final output (user
	#   generated) which the user will generate, and then roc will 
	#   do a final compilation on that file.

	# this is how caddy does it
	# in sum the registry must be generated before compilation

	# Ok, so in our case, cli.roc needs to be very generic and come with 
	# a standard library that we import. All we'll do is validate the 
	# architecture of Command, Backend, Implementation

}

# check_valid : List(Str), Bool -> Bool
# check_valid = |args, expected| Kai.validate(args) == expected
#
# check_render : List(Str), Str -> Bool
# check_render = |args, expected| Kai.render(args) == expected

# Validate catches whether required key combos
# are included.
#
# For example, "pkgs" is required if "shell" is there.
# expect {
# 	config = {
# 		shell: {
# 			pkgs: ["fortune"],
# 		},
# 	}
# 	Kai.render(config)? ==
# 		\\# Generated by kai. Do not edit.
# 		\\{
# 		\\  "description" = "Development environments for Kai developer shell";
# 		\\  "inputs" = {
# 		\\    "nixpkgs" = {
# 		\\      "url" = "github:NixOS/nixpkgs/nixos-unstable";
# 		\\    };
# 		\\  };
# 		\\  "outputs" = { nixpkgs, ... }:
# 		\\    {
# 		\\      "devShells" = {
# 		\\        "x86_64-linux" = {
# 		\\          "default" = nixpkgs."legacyPackages"."x86_64-linux"."mkShell" {
# 		\\            "packages" = [
# 		\\              nixpkgs."legacyPackages"."x86_64-linux"."fortune"
# 		\\            ];
# 		\\          };
# 		\\        };
# 		\\      };
# 		\\    };
# }
