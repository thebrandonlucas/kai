# Pure plugin model shared by plugins and the CLI.
import parser.Body
import parser.Config

Plugin := [
	Module(
		{
			definition : Definition,
			plan : Str, List(Str), HostOs, HostArch -> Try(Plan, Error),
		},
	),
	Registry(RegistryDefinition),
].{
	Error : [InvalidConfig, PlanningFailed(PlanningDiagnostic), UnknownCommand, UnsupportedPlatform]
	HostOs : [LINUX, MACOS, OTHER(Str)]
	HostArch : [X86, X64, ARM, AARCH64, OTHER(Str)]

	run : Plugin, Str, List(Str), HostOs, HostArch -> Try(Plan, Error)
	run = |plugin, config_text, args, os, arch|
		match plugin {
			Module({ definition: _, plan }) => plan(config_text, args, os, arch)
			Registry(registry_definition) => Plugin.plan_registry([registry_definition], config_text, args, os, arch)
		}

	definition : Plugin -> Definition
	definition = |plugin|
		match plugin {
			Module({ definition, plan: _ }) => definition
			Registry({ definition, select_config: _ }) => definition
		}

	# Side effects to be performed by a plugin.
	Action := [
		Exec({ args : List(Str), command : Str }),
		WriteUtf8({ content : Str, path : Str }),
	].{
		encoder_for : _
		parser_for : _
	}

	ActionTemplate : [
		Exec(
			{
				args : List(Str),
				command : Str,
			},
		),
		WriteConfigUtf8({ output : Str, path : Str }),
	]

	ArgumentPolicy : [AllowArguments, NoArguments]

	ConfigBlockRequirement : [OptionalConfigBlock(Str), RequiredConfigBlock(Str)]

	Command := {
		argument_policy : ArgumentPolicy,
		body : Body.Shape,
		config_block : ConfigBlockRequirement,
		default_backend : Str,
		name : Str,
	}

	DeterminateSystemKind : [Custom, Guix, Nix]

	DeterminateSystem := {
		default_package_source : Str,
		driver : [NoDriver, Program(Str)],
		kind : DeterminateSystemKind,
	}

	# Many packages are collections of programs, not
	# runnable binaries themselves.
	Package := {
		name : Str,
		program : Str,
	}

	# If the Backend doesn't have the right prerequisites
	# at runtime (for example, missing the chosen
	# DeterminateSystemKind or missing any other specified Package)
	# then we give a Fallback prompt to help them or advise.
	Fallback := {
		actions : List(Action),
		prompt : [DefaultPrompt, Prompt(Str)],
	}

	Backend := {
		determinate_system : DeterminateSystem,
		fallback : [Fallback(Fallback), NoFallback],
		name : Str,
		required_packages : List(Package),
	}

	SourceLocation := {
		byte_offset : U64,
		column : U64,
		line : U64,
	}

	# location is absolute within the complete config text, including when a
	# plugin selects a block nested inside another generic block.
	LocatedConfigBlock := {
		body : Str,
		location : SourceLocation,
	}

	BackendChoice : [DefaultBackend(Backend), ExplicitBackend(Backend)]

	ConfigSelection : [Missing, Selected(LocatedConfigBlock)]

	SelectorDiagnostic := {
		location : [At(SourceLocation), None],
		message : Str,
	}

	ConfigSelector : Str, Command, BackendChoice, HostOs, HostArch -> Try(ConfigSelection, SelectorDiagnostic)

	RegistryDefinition := {
		definition : Definition,
		select_config : ConfigSelector,
	}

	PlanningDiagnostic := {
		backend : Str,
		command : Str,
		location : [At(SourceLocation), None],
		message : Str,
		plugin : Str,
	}

	# Select the current host's command/backend block, falling back to an
	# unscoped block when the host section does not contain one.
	select_config : ConfigSelector
	select_config = |config_text, command, backend_choice, os, _| {
		block_name = match command.config_block {
			OptionalConfigBlock(name) => name
			RequiredConfigBlock(name) => name
		}
		block_header = match backend_choice {
			DefaultBackend(_) => [block_name]
			ExplicitBackend(backend) => [block_name, backend.name]
		}
		blocks = Config.scan(config_text) ? |diagnostic| {
			location: At(Plugin.source_location(diagnostic.location)),
			message: "invalid plugin configuration",
		}
		host_section = match os {
			LINUX => HostSection("linux")
			MACOS => HostSection("macos")
			_ => NoHostSection
		}
		match host_section {
			NoHostSection => Plugin.select_top_level(blocks, block_header)
			HostSection(section) => {
				host_selection = Config.select_exact(blocks, ["on", section]) ? |selection_error|
					Plugin.top_level_duplicate(selection_error, "duplicate host configuration")
				match host_selection {
					Missing => Plugin.select_top_level(blocks, block_header)
					Selected(host) =>
						match Plugin.select_nested(host, block_header)? {
							Missing => Plugin.select_top_level(blocks, block_header)
							Selected(block) => Ok(Selected(block))
						}
					}
			}
		}
	}

	select_top_level : List(Config.Block), List(Str) -> Try(ConfigSelection, SelectorDiagnostic)
	select_top_level = |blocks, header| {
		selection = Config.select_exact(blocks, header) ? |selection_error|
			Plugin.top_level_duplicate(selection_error, "duplicate command configuration")
		match selection {
			Missing => Ok(Missing)
			Selected(block) => Ok(Selected({ body: block.body, location: Plugin.source_location(block.location) }))
		}
	}

	select_nested : Config.Block, List(Str) -> Try(ConfigSelection, SelectorDiagnostic)
	select_nested = |host, header| {
		blocks = Config.scan(host.body) ? |diagnostic| {
			location: At(Plugin.nested_location(host, diagnostic.location)),
			message: "invalid host configuration",
		}
		selection = Config.select_exact(blocks, header) ? |selection_error| {
			location = match selection_error {
				DuplicateHeader({ first: _, header: _, second }) => At(Plugin.nested_location(host, second))
			}
			{ location, message: "duplicate command configuration" }
		}
		match selection {
			Missing => Ok(Missing)
			Selected(block) => Ok(Selected({ body: block.body, location: Plugin.nested_location(host, block.location) }))
		}
	}

	top_level_duplicate : Config.SelectionError, Str -> SelectorDiagnostic
	top_level_duplicate = |selection_error, message| {
		location = match selection_error {
			DuplicateHeader({ first: _, header: _, second }) => At(Plugin.source_location(second))
		}
		{ location, message }
	}

	nested_location : Config.Block, Config.Location -> SourceLocation
	nested_location = |host, location|
		Plugin.translate_location(
			{ body: host.body, location: Plugin.source_location(host.location) },
			location.byte_offset,
		)

	source_location : Config.Location -> SourceLocation
	source_location = |location| {
		byte_offset: location.byte_offset,
		column: location.column,
		line: location.line,
	}

	RenderContext := {
		args : List(Str),
		config : Body.Configuration,
		config_block : [NoConfigBlock, SelectedConfigBlock(LocatedConfigBlock)],
		host_arch : HostArch,
		host_os : HostOs,
	}

	# Text that will get written to disk.
	# "name" is what our plugin would name
	# the output internally, e.g. "flake",
	# the text is the actual text inside flake.nix
	RenderedOutput := {
		name : Str,
		text : Str,
	}

	RenderResult := {
		outputs : List(RenderedOutput),
		requested_packages : List(Str),
	}

	RendererDiagnostic := {
		byte_offset : [At(U64), None],
		message : Str,
	}

	Renderer : RenderContext -> Try(RenderResult, RendererDiagnostic)

	Implementation := {
		actions : List(ActionTemplate),
		backend : Str,
		command : Str,
		renderer : Renderer,
	}

	Definition := {
		backends : List(Backend),
		commands : List(Command),
		implementations : List(Implementation),
		name : Str,
	}

	Plan := {
		actions : List(Action),
		backend : Backend,
		command : Str,
		plugin : Str,
		requested_packages : List(Str),
	}.{
		encoder_for : _
		parser_for : _
	}

	# Plan the first registry definition that owns the CLI command.
	plan_registry : List(RegistryDefinition), Str, List(Str), HostOs, HostArch -> Try(Plan, Error)
	plan_registry = |registry, config_text, args, os, arch|
		match args {
			[] => Err(UnknownCommand)
			[command_name, .. as command_args] => {
				owner = Plugin.find_owner(registry, command_name)?
				plugin_definition = owner.registry_definition.definition
				command = owner.command
				backend_selection = Plugin.select_backend(plugin_definition.backends, command, command_args) ? |backend_name|
					PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_name, None, "plugin command refers to unknown backend '${backend_name}'"))

				if command.argument_policy == NoArguments and !backend_selection.args.is_empty() {
					Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "command does not accept arguments")))
				} else {
					implementation = Plugin.find_implementation(plugin_definition.implementations, command.name, backend_selection.backend.name) ? |_|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "plugin has no implementation for selected backend"))
					selector = owner.registry_definition.select_config
					selection = selector(config_text, command, backend_selection.choice, os, arch) ? |diagnostic|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, diagnostic.location, diagnostic.message))
					parsed = match selection {
						Missing =>
							match command.config_block {
								RequiredConfigBlock(name) => Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "missing required config block '${name}'")))
								OptionalConfigBlock(_) => Ok({ config: Body.empty, config_block: NoConfigBlock })
							}
						Selected(block) => {
							config = Body.parse(command.body, block.body) ? |diagnostic|
								PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, At(Plugin.translate_location(block, diagnostic.byte_offset)), Body.describe(diagnostic)))
							Ok({ config, config_block: SelectedConfigBlock(block) })
						}
					}?
					context = Plugin.RenderContext.{
						args: backend_selection.args,
						config: parsed.config,
						config_block: parsed.config_block,
						host_arch: arch,
						host_os: os,
					}
					renderer = implementation.renderer
					rendered = renderer(context) ? |diagnostic|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, Plugin.renderer_location(selection, diagnostic.byte_offset), diagnostic.message))
					match Plugin.lower(implementation, rendered, plugin_definition.name, backend_selection.backend) {
						Ok(plan) => Ok(plan)
						Err(diagnostic) => Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, Plugin.renderer_location(selection, diagnostic.byte_offset), diagnostic.message)))
					}
				}
			}
		}

	find_owner : List(RegistryDefinition), Str -> Try({ command : Command, registry_definition : RegistryDefinition }, [UnknownCommand])
	find_owner = |registry, command_name|
		match registry {
			[] => Err(UnknownCommand)
			[first, .. as rest] =>
				match Plugin.find_command(first.definition.commands, command_name) {
					Ok(command) => Ok({ command, registry_definition: first })
					Err(NotFound) => Plugin.find_owner(rest, command_name)
				}
			}

	find_command : List(Command), Str -> Try(Command, [NotFound])
	find_command = |commands, name|
		match commands {
			[] => Err(NotFound)
			[first, .. as rest] =>
				if first.name == name {
					Ok(first)
				} else {
					Plugin.find_command(rest, name)
				}
			}

	find_backend : List(Backend), Str -> Try(Backend, [NotFound])
	find_backend = |backends, name|
		match backends {
			[] => Err(NotFound)
			[first, .. as rest] =>
				if first.name == name {
					Ok(first)
				} else {
					Plugin.find_backend(rest, name)
				}
			}

	select_backend : List(Backend), Command, List(Str) -> Try({ args : List(Str), backend : Backend, choice : BackendChoice }, Str)
	select_backend = |backends, command, args|
		match args {
			[candidate, .. as rest] =>
				match Plugin.find_backend(backends, candidate) {
					Ok(backend) => Ok({ args: rest, backend, choice: ExplicitBackend(backend) })
					Err(NotFound) => Plugin.select_default_backend(backends, command, args)
				}
			[] => Plugin.select_default_backend(backends, command, args)
		}

	select_default_backend : List(Backend), Command, List(Str) -> Try({ args : List(Str), backend : Backend, choice : BackendChoice }, Str)
	select_default_backend = |backends, command, args|
		match Plugin.find_backend(backends, command.default_backend) {
			Ok(backend) => Ok({ args, backend, choice: DefaultBackend(backend) })
			Err(NotFound) => Err(command.default_backend)
		}

	find_implementation : List(Implementation), Str, Str -> Try(Implementation, [NotFound])
	find_implementation = |implementations, command, backend|
		match implementations {
			[] => Err(NotFound)
			[first, .. as rest] =>
				if first.command == command and first.backend == backend {
					Ok(first)
				} else {
					Plugin.find_implementation(rest, command, backend)
				}
			}

	failure : Str, Str, Str, [At(SourceLocation), None], Str -> PlanningDiagnostic
	failure = |plugin, command, backend, location, message| { backend, command, location, message, plugin }

	renderer_location : ConfigSelection, [At(U64), None] -> [At(SourceLocation), None]
	renderer_location = |selection, relative|
		match (selection, relative) {
			(Selected(block), At(byte_offset)) =>
				if byte_offset <= block.body.to_utf8().len() {
					At(Plugin.translate_location(block, byte_offset))
				} else {
					None
				}
			_ => None
		}

	translate_location : LocatedConfigBlock, U64 -> SourceLocation
	translate_location = |block, byte_offset|
		Plugin.translate_bytes(block.body.to_utf8(), byte_offset, 0, block.location)

	translate_bytes : List(U8), U64, U64, SourceLocation -> SourceLocation
	translate_bytes = |bytes, target, index, location|
		if index >= target {
			{
				byte_offset: location.byte_offset + target,
				column: location.column,
				line: location.line,
			}
		} else if (bytes.get(index) ?? 0) == 10 {
			Plugin.translate_bytes(bytes, target, index + 1, { byte_offset: location.byte_offset, column: 1, line: location.line + 1 })
		} else {
			Plugin.translate_bytes(bytes, target, index + 1, { byte_offset: location.byte_offset, column: location.column + 1, line: location.line })
		}

	# Convert pure action templates into a runtime plan.
	lower : Implementation, RenderResult, Str, Backend -> Try(Plan, RendererDiagnostic)
	lower = |implementation, rendered, plugin, backend| {
		actions = Plugin.lower_actions(
			implementation.actions,
			rendered.outputs,
		)?
		Ok(
			Plugin.Plan.{
				actions,
				backend,
				command: implementation.command,
				plugin,
				requested_packages: rendered.requested_packages,
			},
		)
	}

	lower_actions :
		List(ActionTemplate),
		List(RenderedOutput) ->
			Try(List(Action), RendererDiagnostic)
	lower_actions = |templates, outputs|
		match templates {
			[] => Ok([])
			[first, .. as rest] => {
				# At present there are two actions, Exec
				# and WriteConfigUtf8 (write a file).
				# For WriteConfigUtf8, we have a list of rendered
				# output files
				action = match first {
					Exec(exec) => Ok(Exec(exec))

					WriteConfigUtf8({ output, path }) =>
						match Plugin.find_output(outputs, output) {
							Ok(content) => Ok(WriteUtf8({ content, path }))
							Err(diagnostic) => Err(diagnostic)
						}
					}?
				rest_actions = Plugin.lower_actions(rest, outputs)?
				Ok([action].concat(rest_actions))
			}
		}

	find_output : List(RenderedOutput), Str -> Try(Str, RendererDiagnostic)
	find_output = |outputs, expected_name|
		match outputs {
			[] => Err({
				byte_offset: None,
				message: "plugin renderer did not return named output '${expected_name}'",
			})
			[first, .. as rest] =>
				if first.name == expected_name {
					Ok(first.text)
				} else {
					Plugin.find_output(rest, expected_name)
				}
			}
}
