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

  BackendPreference := [
  Automatic,
  Require(Command.Backend),
  ]

	Config : {
		name : Str,
		shell : {
			pkgs : List(Str),
		},
# FIXME: we call it preference but should it be required?
    backend_preference: BackendPreference
	}

  BackendCandidateSource := [
  Environment,
  LocalConfig,
  ]

  BackendCandidate: {
    source: BackendCandidateSource,
    name: Str
  }

  BackendInputProblem := [
  LocalConfigUnreadable(Str),
  LocalConfigMalformed(Str),
  LocalConfigBackendNotString,
  ]

  BackendInput := [
# e.g. the doesn't have nix on their system
  Absent,
  Candidate(BackendCandidate),
  Invalid(BackendInputProblem),

  ]

  DispatchRequest: {
    backend_candidate: BackendInput,
    command: Str,
    args: List(Str),
  }

  DispatchResult: {
    backend: Command.Backend,
    plan : Command.Plan,
    }

    BackendError :=[
    MissingBackend,
    UnsupportedBackend(BackendCandidateSource, Str),
    InvalidBackendInput(BackendInputProblem),
    ]

    DispatchError :=[
    BackendFailed(BackendError),
    RegistryFailed(Command.RegistryError),
    HandlerFailed(Command.Error),
    InvalidPlan(List(Command.ValidationError)),
    ]

config : {
  name : Str,
  shell : {pkgs: List(Str)},

} -> Config 
config = |project | {
  name: project.name,
  shell: project.shell,
  backend_preference: BackendPreference.Automatic,
}

with_backend : Config, Command.Backend -> Config 
with_backend = |config_value, backend| {
  name: config_value.name,
  shell: config_value.shell,
  backend_preference: BackendPreference.Require(backend)
}

registry : Config,
List(CommandChange) -> Try(
Command.Registry,
Command.RegistryError,
)
registry = |config_value, changes| {
  standard = Command.add(
  Command.empty_registry,
  default_nix_shell(config_value),

  )?

  apply_command_changes(changes, standard)
}

resolve_backend : Config -> BackendInput -> Try(Command.Backend, BackendError)
resolve_backend = |config_value, input| 
match config_value.backend_preference {
  BackendPreference.Require(backend) => Ok(backend),
  BackendPreference.Automatic => 
  match input {
    BackendInput.Absent => Err(BackendError.MissingBackend)
    BackendInput.Candidate(candidate) => parse_backend_candidate(candidate)
    BackendInput.Invalid(problem) => Err(BackendError.InvalidBackendInput(problem))
  }
}

dispatch : Config
List(CommandChange),
DispatchRequest -> Try(
DispatchResult
,
DispatchError,
)
dispatch  = |config_value, changes, request| {
  backend = resolve_backend(config_value, request.backend_candidate)
    ? |error| DispatchError.BackendFailed(error)

    configured_registry = registry(config_value, changes)
    ? |error| DispatchError.RegistryFailed(error)

    implementation = Command.select(
    configured_registry,
    request.command,
    backend,
    ) ? |error| DispatchError.RegistryFailed(error)

    handler = implementation.handler 
    plan = handler({
      project: config_value.name,
      backend,
      args: request.args,
      }) ? |error| DispatchError.HandlerFailed(error)

      _ = Command.validate_plan(plan)
      ? |errors| DispatchError.InvalidPlan(errors)

      Ok({backend, plan})
}
	
	

	default_nix_shell : Config -> Command.Implementation
	default_nix_shell = |config_value| {
		command: "shell",
		contract: "kai.shell.v1",
		id: "kai.shell.default.nix",
		backends: [Command.Backend.Nix],
		handler: |_request| {
			match render_source(config_value) {
				Err(error) =>
					Err(Command.Error.PlanningFailed(Str.inspect(error)))
				Ok(source) =>
					Ok({
						files: [
							{
								path: ".kai/generated/flake.nix",
								contents: source,
							},
						],
						argv: ["nix", "develop", "path:.kai/generated#default"],
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

  parse_backend_candidate = |candidate| 
  match candidate.name {
    "nix" => Ok(Command.Backend.Nix)
    unsupported => Err(
    Kai.BackendError.UnsupportedBackend(
    candidate.source,
    unsupported,
    ),
    )
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

required_nix_config : Str, List(Str) -> Kai.Config
required_nix_config = |name, pkgs| 
Kai.with_backend(test_config(name, pkgs), Command.Backend.Nix,)

backend_candidate : Kai.BackendCandidateSource, Str -> Kai.BackendInput
backend_candidate = |source, name| 
  Kai.BackendInput.Candidate({source, name})

  dispatch_request : Kai.BackendInput, Str, List(Str) -> Kai.DispatchRequest
  dispatch_request = |candidate, command, args| {
    backend_candidate: candidate,
    command,
    args,
  }

  planning_handler : Command.Handler
  planning_handler = |_request| 
  Ok({
    files: [{path: "./kai/generated/custom", contents: "custom"}]
    ,
    argv: ["custom", "run"]

    })

  failing_handler : Command.Handler 
  failing_handler = |_request| 
  Err(Command.Error.PlanningFailed("module rejected project"))

  empty_argv_handler : Command.Handler 
  empty_argv_handler = |_request| 
  Ok({files: [], argv: []})

  echo_argv_handler : Command.Handler 
  echo_argv_handler = |request| 
  Ok({files: [], argv: request.args})

  shell_implementation : Str, Command.Handler -> Command.Implementation 
  shell_implementation = |id, handler| {
    command: "shell",
    contract: "kai.shell.v1",
    id,
    backends: [Command.Backend.Nix],
    handler,

  }

  doctor_implementation : Str, Command.Handler -> Command.Implementation 
  doctor_implementation =  {
    command: "doctor",
    contract: "kai.doctor.v1",
    id: "example.doctor.nix",
    backends: [Command.Backend.Nix],
    handler: echo_argv_handler,

  }

shell_request : Command.Request 
shell_request = {
  project: "shell plan",
  backend: Command.Backend.Nix,
  args: [],
}

shell_plan_config : Kai.Config 
shell_plan_config = test_config(
"shell plan",
# test duplicate handling
["git", "git", "curl"]
)

automatic_backend_config : Kai.Config 
automatic_backend_config = test_config(
"backend resolution",
["git"]
)

required_nix_backend_config : Kai.Config 
required_nix_backend_config = Kai.with_backend(
automatic_backend_config,
Command.Backend.Nix
)

## Kai.config preserves standard project fields and chooses automatic policy.
expect {
  config_value = test_config("example", ["git", "curl"])
  fields_preserved = config_value.name == "example"
    and config_value.shell.pkgs  == ["git", "curl"]
    preference_is_automatic = match config_value.backend_preference {
      Kai.BackendPreference.Automatic == Bool.True 
      _ Bool.False
    }

    fields_preserved and preference_is_automatic
}

# Kai.with_backend changes only backend policy.
expect {
	config_value = required_nix_config("example", ["git", "curl"])
	fields_preserved = config_value.name == "example"
		and config_value.shell.pkgs == ["git", "curl"]
	preference_requires_nix = match config_value.backend_preference {
		Kai.BackendPreference.Require(Command.Backend.Nix) => Bool.True
		_ => Bool.False
	}

	fields_preserved and preference_requires_nix
}

# Duplicate package declarations produce the same rendered source.
expect {
	with_duplicates = render_source(test_config("example", ["git", "git", "curl"]))?
	without_duplicates = render_source(test_config("example", ["git", "curl"]))?

	with_duplicates == without_duplicates
}

# Invalid project data preserves Blueprint validation failures.
expect {
	match render_source(test_config("", ["git"])) {
		Err(BlueprintInvalid([Blueprint.Error.EmptyWorkspaceName])) => Bool.True
		_ => Bool.False
	}
}

expect {
	match render_source(test_config("example", [""])) {
		Err(BlueprintInvalid([Blueprint.Error.EmptyRequirementId("default")])) => Bool.True
		_ => Bool.False
	}
}

# The standard implementation has stable identity and is valid.
expect {
	implementation = Kai.default_nix_shell(shell_plan_config)
	exact_backends = match implementation.backends {
		[Command.Backend.Nix] => Bool.True
		_ => Bool.False
	}
	valid = match Command.validate_implementation(implementation) {
		Ok({}) => Bool.True
		Err(_) => Bool.False
	}

	implementation.command == "shell"
		and implementation.contract == "kai.shell.v1"
			and implementation.id == "kai.shell.default.nix"
				and exact_backends
					and valid
}

# The standard plan uses the managed generated-output root exactly.
expect {
	implementation = Kai.default_nix_shell(shell_plan_config)
	handler = implementation.handler
	plan = handler(shell_request)?

	expected_source = "# Generated by roc-blueprint and roc-blueprint-nix. Do not edit.\n{\n  \"description\" = \"Development environments for shell plan\";\n  \"inputs\" = {\n    \"nixpkgs\" = {\n      \"url\" = \"github:NixOS/nixpkgs/nixos-unstable\";\n    };\n  };\n  \"outputs\" = { nixpkgs, ... }:\n    {\n      \"devShells\" = {\n        \"x86_64-linux\" = {\n          \"default\" = nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"mkShell\" {\n            \"packages\" = [\n              nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"git\"\n              nixpkgs.\"legacyPackages\".\"x86_64-linux\".\"curl\"\n            ];\n          };\n        };\n      };\n    };\n}"

	plan.files == [
		{
			path: ".kai/generated/flake.nix",
			contents: expected_source,
		},
	]
		and plan.argv == ["nix", "develop", "path:.kai/generated#default"]
}

# Empty custom changes retain the standard shell implementation.
expect {
	registry = Kai.registry(shell_plan_config, [])?
	selected = Command.select(registry, "shell", Command.Backend.Nix)?

	selected.id == "kai.shell.default.nix"
}

# A separately supplied replacement wins.
expect {
	replacement = shell_implementation("example.shell.replacement.nix", planning_handler)
	registry = Kai.registry(
		shell_plan_config,
		[Kai.CommandChange.Replace(replacement)],
	)?
	selected = Command.select(registry, "shell", Command.Backend.Nix)?

	selected.id == "example.shell.replacement.nix"
}

# Add and Replace changes are applied in declaration order.
expect {
	replacement_doctor = {
		command: "doctor",
		contract: "kai.doctor.v1",
		id: "example.doctor.replacement.nix",
		backends: [Command.Backend.Nix],
		handler: planning_handler,
	}
	registry = Kai.registry(
		shell_plan_config,
		[
			Kai.CommandChange.Add(doctor_implementation),
			Kai.CommandChange.Replace(replacement_doctor),
		],
	)?
	selected = Command.select(registry, "doctor", Command.Backend.Nix)?

	selected.id == "example.doctor.replacement.nix"
}

# Registry failures preserve their exact structure.
expect {
	match Kai.registry(
		shell_plan_config,
		[Kai.CommandChange.Add(shell_implementation("duplicate.shell.nix", planning_handler))],
	) {
		Err(Command.RegistryError.DuplicateRegistration("shell", Command.Backend.Nix)) =>
			Bool.True
		_ => Bool.False
	}
}

expect {
	wrong_contract = {
		command: "shell",
		contract: "example.shell.v2",
		id: "example.shell.wrong-contract.nix",
		backends: [Command.Backend.Nix],
		handler: planning_handler,
	}
	match Kai.registry(
		shell_plan_config,
		[Kai.CommandChange.Replace(wrong_contract)],
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

# A required backend wins over every lower-priority input.
expect {
	match Kai.resolve_backend(required_nix_backend_config, Kai.BackendInput.Absent) {
		Ok(Command.Backend.Nix) => Bool.True
		_ => Bool.False
	}
}

expect {
	match Kai.resolve_backend(
		required_nix_backend_config,
		backend_candidate(Kai.BackendCandidateSource.Environment, "nix"),
	) {
		Ok(Command.Backend.Nix) => Bool.True
		_ => Bool.False
	}
}

expect {
	match Kai.resolve_backend(
		required_nix_backend_config,
		backend_candidate(Kai.BackendCandidateSource.Environment, "guix"),
	) {
		Ok(Command.Backend.Nix) => Bool.True
		_ => Bool.False
	}
}

expect {
	match Kai.resolve_backend(
		required_nix_backend_config,
		Kai.BackendInput.Invalid(
			Kai.BackendInputProblem.LocalConfigMalformed("missing equals"),
		),
	) {
		Ok(Command.Backend.Nix) => Bool.True
		_ => Bool.False
	}
}

# Automatic policy accepts exact Nix candidates from both sources.
expect {
	environment_result = Kai.resolve_backend(
		automatic_backend_config,
		backend_candidate(Kai.BackendCandidateSource.Environment, "nix"),
	)
	local_result = Kai.resolve_backend(
		automatic_backend_config,
		backend_candidate(Kai.BackendCandidateSource.LocalConfig, "nix"),
	)

	match (environment_result, local_result) {
		(Ok(Command.Backend.Nix), Ok(Command.Backend.Nix)) => Bool.True
		_ => Bool.False
	}
}

# Automatic policy reports absence and preserves sourced failures.
expect {
	match Kai.resolve_backend(automatic_backend_config, Kai.BackendInput.Absent) {
		Err(Kai.BackendError.MissingBackend) => Bool.True
		_ => Bool.False
	}
}

expect {
	input_problem = Kai.BackendInputProblem.LocalConfigUnreadable("permission denied")
	match Kai.resolve_backend(
		automatic_backend_config,
		Kai.BackendInput.Invalid(input_problem),
	) {
		Err(
			Kai.BackendError.InvalidBackendInput(
				Kai.BackendInputProblem.LocalConfigUnreadable("permission denied"),
			),
		) => Bool.True
		_ => Bool.False
	}
}

expect {
	input_problem = Kai.BackendInputProblem.LocalConfigMalformed("missing equals")
	match Kai.resolve_backend(
		automatic_backend_config,
		Kai.BackendInput.Invalid(input_problem),
	) {
		Err(
			Kai.BackendError.InvalidBackendInput(
				Kai.BackendInputProblem.LocalConfigMalformed("missing equals"),
			),
		) => Bool.True
		_ => Bool.False
	}
}

expect {
	match Kai.resolve_backend(
		automatic_backend_config,
		Kai.BackendInput.Invalid(
			Kai.BackendInputProblem.LocalConfigBackendNotString,
		),
	) {
		Err(
			Kai.BackendError.InvalidBackendInput(
				Kai.BackendInputProblem.LocalConfigBackendNotString,
			),
		) => Bool.True
		_ => Bool.False
	}
}

# Unsupported candidates preserve their source and exact raw value.
expect {
	match Kai.resolve_backend(
		automatic_backend_config,
		backend_candidate(Kai.BackendCandidateSource.Environment, "guix"),
	) {
		Err(
			Kai.BackendError.UnsupportedBackend(
				Kai.BackendCandidateSource.Environment,
				"guix",
			),
		) => Bool.True
		_ => Bool.False
	}
}

expect {
	match Kai.resolve_backend(
		automatic_backend_config,
		backend_candidate(Kai.BackendCandidateSource.LocalConfig, ""),
	) {
		Err(
			Kai.BackendError.UnsupportedBackend(
				Kai.BackendCandidateSource.LocalConfig,
				"",
			),
		) => Bool.True
		_ => Bool.False
	}
}

# Automatic and required configs dispatch the standard shell.
expect {
	environment_result = Kai.dispatch(
		automatic_backend_config,
		[],
		dispatch_request(
			backend_candidate(Kai.BackendCandidateSource.Environment, "nix"),
			"shell",
			[],
		),
	)?
	local_result = Kai.dispatch(
		automatic_backend_config,
		[],
		dispatch_request(
			backend_candidate(Kai.BackendCandidateSource.LocalConfig, "nix"),
			"shell",
			[],
		),
	)?
	required_result = Kai.dispatch(
		required_nix_backend_config,
		[],
		dispatch_request(Kai.BackendInput.Absent, "shell", []),
	)?

	environment_result.plan.argv == ["nix", "develop", "path:.kai/generated#default"]
		and local_result.plan.argv == environment_result.plan.argv
			and required_result.plan.argv == environment_result.plan.argv
}

# Required policy ignores unsupported and malformed lower-priority inputs during dispatch.
expect {
	unsupported = Kai.dispatch(
		required_nix_backend_config,
		[],
		dispatch_request(
			backend_candidate(Kai.BackendCandidateSource.Environment, "guix"),
			"shell",
			[],
		),
	)
	malformed = Kai.dispatch(
		required_nix_backend_config,
		[],
		dispatch_request(
			Kai.BackendInput.Invalid(
				Kai.BackendInputProblem.LocalConfigMalformed("bad document"),
			),
			"shell",
			[],
		),
	)

	unsupported_is_nix = match unsupported {
		Ok({ backend: Command.Backend.Nix, plan: _ }) => Bool.True
		_ => Bool.False
	}
	malformed_is_nix = match malformed {
		Ok({ backend: Command.Backend.Nix, plan: _ }) => Bool.True
		_ => Bool.False
	}

	unsupported_is_nix and malformed_is_nix
}

# Backend failures occur before invalid composition can be observed.
expect {
	duplicate = Kai.CommandChange.Add(
		shell_implementation("duplicate.shell.nix", planning_handler),
	)
	match Kai.dispatch(
		automatic_backend_config,
		[duplicate],
		dispatch_request(Kai.BackendInput.Absent, "shell", []),
	) {
		Err(Kai.DispatchError.BackendFailed(Kai.BackendError.MissingBackend)) =>
			Bool.True
		_ => Bool.False
	}
}

expect {
	duplicate = Kai.CommandChange.Add(
		shell_implementation("duplicate.shell.nix", planning_handler),
	)
	match Kai.dispatch(
		automatic_backend_config,
		[duplicate],
		dispatch_request(
			Kai.BackendInput.Invalid(
				Kai.BackendInputProblem.LocalConfigBackendNotString,
			),
			"shell",
			[],
		),
	) {
		Err(
			Kai.DispatchError.BackendFailed(
				Kai.BackendError.InvalidBackendInput(
					Kai.BackendInputProblem.LocalConfigBackendNotString,
				),
			),
		) => Bool.True
		_ => Bool.False
	}
}

# Dispatch applies replacement composition and returns its exact plan.
expect {
	replacement = shell_implementation("example.shell.dispatch.nix", planning_handler)
	result = Kai.dispatch(
		required_nix_backend_config,
		[Kai.CommandChange.Replace(replacement)],
		dispatch_request(Kai.BackendInput.Absent, "shell", ["ignored"]),
	)?

	backend_is_nix = match result.backend {
		Command.Backend.Nix => Bool.True
	}

	backend_is_nix
		and result.plan == {
			files: [{ path: ".kai/generated/custom", contents: "custom" }],
			argv: ["custom", "run"],
		}
}

# Dispatch preserves selection, registration, handler, and plan errors.
expect {
	match Kai.dispatch(
		required_nix_backend_config,
		[],
		dispatch_request(Kai.BackendInput.Absent, "doctor", []),
	) {
		Err(
			Kai.DispatchError.RegistryFailed(
				Command.RegistryError.UnknownCommand("doctor"),
			),
		) => Bool.True
		_ => Bool.False
	}
}

expect {
	duplicate = shell_implementation("duplicate.shell.nix", planning_handler)
	match Kai.dispatch(
		required_nix_backend_config,
		[Kai.CommandChange.Add(duplicate)],
		dispatch_request(Kai.BackendInput.Absent, "shell", []),
	) {
		Err(
			Kai.DispatchError.RegistryFailed(
				Command.RegistryError.DuplicateRegistration(
					"shell",
					Command.Backend.Nix,
				),
			),
		) => Bool.True
		_ => Bool.False
	}
}

expect {
	replacement = shell_implementation("example.shell.failing.nix", failing_handler)
	match Kai.dispatch(
		required_nix_backend_config,
		[Kai.CommandChange.Replace(replacement)],
		dispatch_request(Kai.BackendInput.Absent, "shell", []),
	) {
		Err(
			Kai.DispatchError.HandlerFailed(
				Command.Error.PlanningFailed("module rejected project"),
			),
		) => Bool.True
		_ => Bool.False
	}
}

expect {
	replacement = shell_implementation("example.shell.empty-argv.nix", empty_argv_handler)
	match Kai.dispatch(
		required_nix_backend_config,
		[Kai.CommandChange.Replace(replacement)],
		dispatch_request(Kai.BackendInput.Absent, "shell", []),
	) {
		Err(
			Kai.DispatchError.InvalidPlan(
				[
					Command.ValidationError.EmptyPlanArgv,
				],
			),
		) => Bool.True
		_ => Bool.False
	}
}

# Dispatch preserves argument ordering, spaces, and empty strings.
expect {
	args = ["first", "two words", "", "last"]
	replacement = shell_implementation("example.shell.echo-args.nix", echo_args_handler)
	result = Kai.dispatch(
		required_nix_backend_config,
		[Kai.CommandChange.Replace(replacement)],
		dispatch_request(Kai.BackendInput.Absent, "shell", args),
	)?

	result.plan.argv == args
}
