## Command - A
Command := [].{
	Backend := [Nix]

	File : {
		path : Str,
		contents : Str,
	}

	Plan : {
		files : List(File),
		argv : List(Str),
	}

	Request : {
		project : Str,
		backend : Backend,
		args : List(Str),
	}

	Error := [
		PlanningFailed(Str),
	]

	Handler : Request -> Try(Plan, Error)

	Implementation : {
		command : Str,
		# Asks what behavior and data semantics implementations must preserve
		contract : Str,
		id : Str,
		backends : List(Backend),
		handler : Handler,
	}

	ValidationError := [EmptyCommand, EmptyContract, EmptyImplementationId, EmptyPlanArgv, NoBackends]

	validate_implementation : Implementation -> Try({}, List(ValidationError))
	validate_implementation = |implementation| {
		initial = if implementation.command == "" [EmptyCommand] else []

		with_contract = if implementation.contract == "" {
			initial.append(EmptyContract)
		}
			else {
				initial
			}

		with_id = if implementation.id == "" {
			with_contract.append(EmptyImplementationId)
		} else
			{
				with_contract
			}

		errors = if implementation.backends.is_empty() {
			with_id.append(NoBackends)
		} else
			{
				with_id
			}

		if errors.is_empty() Ok({}) else Err(errors)
	}

	validate_plan : Plan -> Try({}, List(ValidationError))
	validate_plan = |plan| {
		if plan.argv.is_empty() {
			Err([EmptyPlanArgv])
		} else {
			Ok({})
		}
	}

	supports_backend : Implementation, Backend -> Bool
	supports_backend = |implementation, backend|
		implementation.backends.contains(backend)

	Registry :: List(Implementation)
	RegistryError := [

		# AmbiguousRegistration(Str, Backend),
		#
		## command, backend, existing contract, replacement contract
		ContractMismatch(Str, Backend, Str, Str),
		DuplicateRegistration(Str, Backend),

		InvalidImplementation(List(ValidationError)),
		MissingRegistration(Str, Backend),
		UnknownCommand(Str),
		UnsupportedBackend(Str, Backend),
	]
	empty_registry : Registry
	empty_registry = Registry.([])

	## Select a command implementation from the registry and return it.
	## registry: The full registry to select from and iterate over.
	## command: The command string to match on
	## backend: the backend (e.g. nix) to use.
	select : Registry, Str, Backend -> Try(Implementation, RegistryError)
	select = |Registry.(implementations), command, backend| {
		match implementations.find_first(
			|implementation|
				implementation.command == command
					and
					implementation.backends.contains(backend),
		) {
			Ok(implementation) => Ok(implementation)
			Err(NotFound) =>
			# If we didn't find an exact match,
			# check whether it's the command or the
			# backend that failed to match.
				if implementations.any(
					|implementation| implementation.command == command,
				) {
					Err(UnsupportedBackend(command, backend))
				} else {
					Err(UnknownCommand(command))
				}
			}
	}

	## Command registry items will be unique per (backend, command)
	add : Registry, Implementation -> Try(Registry, RegistryError)
	add = |Registry.(implementations), implementation| {

		match validate_implementation(implementation) {
			Err(errors) => Err(InvalidImplementation(errors))
			Ok({}) =>
				match implementation.backends.find_first(
					|backend|
						command_exists(
							implementations,
							implementation.command,
							backend,
						),
				) {
					Ok(backend) => Err(
						DuplicateRegistration(
							implementation.command,
							backend,
						),
					)
					Err(NotFound) => Ok(
						Registry.(
							implementations.append(implementation),
						),
					)
				}
			}
	}

	## Find the (command, backend) slots that match the replacement
	## and replace them while preserving unrelated backend slots.
	replace : Registry, Implementation -> Try(Registry, RegistryError)
	replace = |Registry.(implementations), replacement| {
		match validate_implementation(replacement) {
			Err(errors) => Err(InvalidImplementation(errors))
			Ok({}) =>
				match validate_replacement_slots(
					implementations,
					replacement,
					replacement.backends,
				) {
					Err(error) => Err(error)
					Ok({}) => {
						remaining = remove_replaced_slots(
							implementations,
							replacement,
						)

						Ok(Registry.(remaining.append(replacement)))
					}
				}
			}
	}

	validate_replacement_slots :
		List(Implementation),
		Implementation,
		List(Backend) -> Try({}, RegistryError)
	validate_replacement_slots = |implementations, replacement, backends|
		match backends {
			[] => Ok({})
			[backend, .. as rest] =>
				match implementations.find_first(
					|existing|
						existing.command == replacement.command
							and existing.backends.contains(backend),
				) {
					Err(NotFound) =>
						Err(
							MissingRegistration(
								replacement.command,
								backend,
							),
						)
					Ok(existing) =>
						if existing.contract != replacement.contract {
							Err(
								ContractMismatch(
									replacement.command,
									backend,
									existing.contract,
									replacement.contract,
								),
							)
						} else {
							validate_replacement_slots(
								implementations,
								replacement,
								rest,
							)
						}
					}
			}

	remove_replaced_slots :
		List(Implementation),
		Implementation -> List(Implementation)
	remove_replaced_slots = |implementations, replacement|
		match implementations {
			[] => []
			[existing, .. as rest] => {
				processed_rest = remove_replaced_slots(rest, replacement)

				if existing.command != replacement.command {
					processed_rest.prepend(existing)
				} else {
					remaining_backends = existing.backends.keep_if(
						|backend| !replacement.backends.contains(backend),
					)

					if remaining_backends.is_empty() {
						processed_rest
					} else {
						processed_rest.prepend({
							command: existing.command,
							contract: existing.contract,
							id: existing.id,
							backends: remaining_backends,
							handler: existing.handler,
						})
					}
				}
			}
		}

	#

	# FIXME: what should a registry item be unique on? should 
	# commands just be unique on merely the command name or should they 
	# be unique on (command, backend) or some other combo?

	# I'm thinking (command, backend) is good b/c you will need custom 
	# implementations per command. for ex. we could have multi different
	# shell commands:
	# 
	# shell -> ("shell", Nix)
	# shell -> ("shell", Guix)
	# shell -> ("shell", Kai-Custom)
	# shell -> ("shell", [Nix, Snix]) i.e., we replace nix shell behavior with snix shell (which is compatible with nix)

	## if a (command, backend) combo already exists,
	## error and return that (command, backend) combo so that 
	## the error can be specific.

	# utility to check if command already exists in registry.
	# # commands select they select by (command, backend) so that's what we're checking for
	command_exists : List(Implementation), Str, Backend -> Bool
	command_exists = |implementations, command, backend| {
		implementations.any(
			|implementation|
				implementation.command == command
					and
					implementation.backends.contains(backend),
		)
	}

	## Return the implementation that matches the 
	## (command, backend) provided, if any
	get_implementation : Registry, Str, Backend -> Try(Implementation, RegistryError)
	get_implementation = |Registry.(implementations), command, backend| {
		match implementations.find_first(
			|impl|
				impl.command == command
					and
					impl.backends.contains(backend),
		) {
			Ok(matched) => Ok(matched)
			Err(NotFound) =>
				if implementations.any(|impl| impl.command == command) {
					Err(UnsupportedBackend(command, backend))
				} else {
					Err(UnknownCommand(command))
				}
			}
	}

}

handler : Command.Handler
handler = |request| {
	# should these be typed enums or something rather than strings?
	if request.project == "" {
		Err(Command.Error.PlanningFailed("empty project"))
	} else {
		Ok({
			files: [],
			argv: ["nix", "--version"],
		})
	}
}

implementation : Str, Str, Str, List(Command.Backend) -> Command.Implementation
implementation = |command, contract, id, backends| {
	command,
	contract,
	id,
	backends,
	handler,
}

valid_nix_implementation : Command.Implementation
valid_nix_implementation = implementation(
	"doctor",
	"example.doctor.v1",
	"example.doctor.nix",
	[Command.Backend.Nix],
)

default_shell : Command.Implementation
default_shell = implementation(
	"shell",
	"kai.shell.v1",
	"kai.shell.default.nix",
	[Command.Backend.Nix],
)

replacement_shell : Command.Implementation
replacement_shell = implementation(
	"shell",
	"kai.shell.v1",
	"kai.shell.custom.nix",
	[Command.Backend.Nix],
)

doctor : Command.Implementation
doctor = implementation(
	"doctor",
	"kai.doctor.v1",
	"kai.doctor.nix",
	[Command.Backend.Nix],
)

wrong_contract_shell : Command.Implementation
wrong_contract_shell = implementation(
	"shell",
	"example.shell.v2",
	"example.shell.wrong-contract.nix",
	[Command.Backend.Nix],
)

unsupported_shell : Command.Implementation
unsupported_shell = implementation(
	"shell",
	"kai.shell.v1",
	"example.shell.unsupported",
	[Command.Backend.Nix],
)

# guix_shell : Command.Implementation
# guix_shell = implementation(
# 	"guix",
# 	"kai.shell.v1",
# 	"kai.shell.guix",
# 	[Command.Backend.Guix],
# )

# TODO
# custom_backend : Command.Implementation
# guix = 
# -- TESTS -- 
# TODO: refactor to matklad's "How to test"
# "Check" function strategy for easier refactors.

# A complete Nix implementation is valid 
expect Command.validate_implementation(
	valid_nix_implementation,
) == Ok({})

## Command identity is required 
expect Command.validate_implementation(
	implementation(
		"",
		"example.doctor.v1",
		"example.doctor.nix",
		[Command.Backend.Nix],
	),
) == Err([
	Command.ValidationError.EmptyCommand,
])

## Implementation Identity is required 
expect Command.validate_implementation(
	implementation(
		"doctor",
		"example.doctor.v1",
		"",
		[Command.Backend.Nix],
	),
) == Err([
	Command.ValidationError.EmptyImplementationId,
])

## A plan must name an executable 
expect Command.validate_plan({
	files: [],
	argv: [],

}) == Err([
	Command.ValidationError.EmptyPlanArgv,
])

## The implementation declares Nix compatibility
expect Command.supports_backend(
	valid_nix_implementation,
	Command.Backend.Nix,
)

## An implementation with no backends does not support Nix.
expect !Command.supports_backend(
	implementation(
		"doctor",
		"example.doctor.v1",
		"example.doctor.none",
		[],
	),
	Command.Backend.Nix,
)

## Contract identity is required.
expect Command.validate_implementation(
	implementation(
		"doctor",
		"",
		"example.doctor.nix",
		[Command.Backend.Nix],
	),
) == Err([
	Command.ValidationError.EmptyContract,
])

## Missing contract should fail.
expect Command.validate_implementation(
	implementation(
		"doctor",
		"",
		"example.doctor.nix",
		[],
	),
) == Err([
	Command.ValidationError.EmptyContract,
	Command.ValidationError.NoBackends,
])

## A registered Nix shell can be selected
expect {
	registry = Command.add(
		Command.empty_registry,
		default_shell,
	)?
	selected = Command.select(
		registry,
		"shell",
		Command.Backend.Nix,
	)?

	selected.id == "kai.shell.default.nix"
		and selected.contract == "kai.shell.v1"
}

## A previously unknown command can be added 
expect {
	with_shell = Command.add(
		Command.empty_registry,
		default_shell,
	)?

	with_doctor = Command.add(
		with_shell,
		doctor,
	)?

	selected = Command.select(
		with_doctor,
		"doctor",
		Command.Backend.Nix,
	)?

	selected.id == "kai.doctor.nix"
}

## Add rejects an occupied command/backend slot.
expect {
	registry = Command.add(
		Command.empty_registry,
		default_shell,
	)?

	match Command.add(registry, default_shell) {
		Err(
			Command.RegistryError.DuplicateRegistration(
				"shell",
				Command.Backend.Nix,
			),
		) => Bool.True

		_ => Bool.False
	}
}

## Replace installs an implementation with the same contract
expect {
	registry = Command.add(
		Command.empty_registry,
		default_shell,
	)?

	replacement = Command.replace(
		registry,
		replacement_shell,
	)?

	selected = Command.select(
		replacement,
		"shell",
		Command.Backend.Nix,
	)?

	selected.id == "kai.shell.custom.nix"
		and selected.contract == "kai.shell.v1"

}

## Replace rejects a command/backend slot that doesn't exist
expect {
	registry = Command.add(
		Command.empty_registry,
		# Use a different command than shell 
		# so replace will fail
		doctor,
	)?

	match Command.replace(
		registry,
		replacement_shell,
	) {
		Err(
			Command.RegistryError.MissingRegistration(
				"shell",
				Command.Backend.Nix,
			),
		) => Bool.True
		_ => Bool.False
	}
}

## Replace preserves the existing command contract
expect {
	registry = Command.add(
		Command.empty_registry,
		default_shell,
	)?

	match Command.replace(
		registry,
		wrong_contract_shell,
	) {
		Err(
			Command.RegistryError.ContractMismatch(
				"shell",
				Command.Backend.Nix,
				"kai.shell.v1",
				"example.shell.v2",
			),
		) => Bool.True
		_ => Bool.False
	}
}
