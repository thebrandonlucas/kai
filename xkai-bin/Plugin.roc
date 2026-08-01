# Each kai plugin must define: 
# - Command 
# - Backend 
# - Implementation
#
# Where Command is generic like so: 

# shell = Command {
#   name: "shell",
#   backends: [Backend.Nix],
#   inputs: {
#     pkgs: List(Str)
#   },
#   outputs: {
#     "<flake.nix string>"
#   }
# }
#
# Backend is defined like: 
# {
#   name: "nix",
#   commands: [shell, build],
# }
#
# implementation is the actual logic that 
# spits out data and defines the effects that 
# need to be done with said data
# Implementation 
# {
# command: shell # Command,
# backends: [Backend.Nix] # implementation needs to know which types 
# # it needs to know when/where/how to perform these effects,
# # essentially it's not just "do these effects with these vars",
# # but when and in which order and under what conditions, in which 
# # case it is tied to the logic of the handler
# # perhaps we can just admit for now that the handler will be effectful 
# # and figure out how to make those boundaries crisper later.
#
# # for now, just make handler do the thing (write the flake.nix)
# # in this case it is a void function assumes/reads a kai.roc
# # in the current dir and makes a `.kai/flake.nix` file and 
# # enters the shell
# handler: Fn -> Void
# }
#
# Command : {
#   name : Str,
# # Some don't need backends.
# # i.e. maybe deploy just assumes an 
# # artifact is available regardless of Backend.
#   backends : Optional<List(Backend)>,
#   argv : List(Str),
# }
#
# Backend : {
#   name: Str,
#   commands: List(Command)
#   }
#
#   Implementation : {
# command: Command,
# backend: Backend,
# handler : Fn => Void
#
#     }
#
# Plugin : {
#   name: Str,
#   commands: List(Command),
#   backends: List(Backend),
#   implementation: List(Implementation),
# # For THIS command structure, and THIS backend 
# # and THIS implementation, ensure the boundaries 
# # are correct.
#   validator: Fn -> Void
# }
#
# shell : Command
# shell = Command.{
#   name: "shell",
#   backends: [Backend.Nix],
#   argv: [],
# }
#
# nix : Backend
# nix = Backend.Nix
#
# # validate_shell: Try(Void, _)
# # validate_shell = |_| {
# #   # check if the boundaries btwn the Plugin pieces work
# # # i.e. check if the Plugin was instantiated correclty
# # }
#
# handle_shell: Try(Void, _)
# handle_shell = |_| {
#   echo!("handling")
# }
#
# impl : Implementation
# impl = {
#   command: shell,
#   backend: nix,
# # implement the actual code
#   handler: shell_handle
# }
#
# plugin : Plugin 
# plugin = Plugin.new(command, backends, impl,) 
#   
# goal: wire up 1 Plugin given the thing above,
# and just print it's name

# We need a function which ensures that for 
# this Command and this Backend, this Impl does 
# what it's supposed to

Plugin(arg, run_error) := {
	name : Str,
	commands : List(Command),
	backends : List(Backend),
	implementations : List(Implementation(run_error)),
	validator : {} -> {},
	run! : List(arg) => Try({}, run_error),
}.{
	Command := {
		name : Str,
		backends : List(Backend),
		argv : List(Str),
	}

	# TODO: should we type the possible backends instead of 
	# just a named str?
	# also shouldn't this be a list?
	# why did we choose this named str? so that it can be freeform?

	Backend := {
		name : Str,
	}

	Implementation(handler_error) :: {
		command : Command,
		backend : Backend,
		handler! : {} => Try({}, handler_error),
	}.{
		# constructor
		new :
			Command,
			Backend,
			({} => Try({}, handler_error)) -> Implementation(handler_error)
		new = |command, backend, handler!| Implementation.{
			command,
			backend,
			handler!,
		}

		run! : Implementation(handler_error) => Try({}, handler_error)
		run! = |implementation|
			match implementation {
				# FIXME: does this say Perform handler, 
				# which takes in nothing, and and performs side effects?
				{ handler!, .. } => handler!({})
			}
	}
}
