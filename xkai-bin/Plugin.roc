# Pure plugin model shared by plugins and the CLI.
import parser.Body
import parser.Config

Plugin := [].{
	Error : [PlanningFailed(PlanningDiagnostic), UnknownCommand]
	HostOs : [LINUX, MACOS, OTHER(Str)]
	HostArch : [X86, X64, ARM, AARCH64, OTHER(Str)]

	# Side effects to be performed by a plugin.
	Action := [
		Exec({ args : List(Str), command : Str }),
		PrintLine(Str),
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

	AsciiByte : [AsciiDigit, AsciiLowercase, AsciiUppercase, ExactByte(U8)]
	ByteRange := { max : U8, min : U8 }

	TextRule : [
		AllBytes({ allowed : List(AsciiByte), message : Str }),
		BytesInRanges({ excluded : List(U8), message : Str, ranges : List(ByteRange) }),
		DisallowedPrefix({ message : Str, prefix : Str }),
		DotSeparatedNonemptySegments(Str),
		ForbiddenPathSegments({ message : Str, segments : List(Str) }),
		NonemptyText(Str),
	]

	StringListRule : [
		AllStrings(TextRule),
		NonemptyFirstString(Str),
		NonemptyStringList(Str),
	]

	# Validation definitions are data. Engines retain every failure in rule
	# order so one diagnostic can report independent problems together.
	validate_text : Str, List(TextRule) -> List(Str)
	validate_text = |value, rules|
		match rules {
			[] => []
			[first, .. as rest] => {
				passes = match first {
					NonemptyText(_) => !value.is_empty()
					DisallowedPrefix({ message: _, prefix }) => !value.starts_with(prefix)
					AllBytes({ allowed, message: _ }) => List.all(value.to_utf8(), |byte| Plugin.byte_matches_any(byte, allowed))
					BytesInRanges({ excluded, message: _, ranges }) =>
						List.all(
							value.to_utf8(),
							|byte| List.any(ranges, |range| byte >= range.min and byte <= range.max) and !excluded.contains(byte),
						)
					# A missing value is covered by NonemptyText rather than producing
					# a dependent second failure.
					DotSeparatedNonemptySegments(_) => value.is_empty() or List.all(value.split_on("."), |part| !part.is_empty())
					ForbiddenPathSegments({ message: _, segments }) => !List.any(value.split_on("/"), |part| List.any(segments, |segment| part == segment))
				}
				message = match first {
					NonemptyText(rule_message) => rule_message
					DisallowedPrefix({ message: rule_message, prefix: _ }) => rule_message
					AllBytes({ allowed: _, message: rule_message }) => rule_message
					BytesInRanges({ excluded: _, message: rule_message, ranges: _ }) => rule_message
					DotSeparatedNonemptySegments(rule_message) => rule_message
					ForbiddenPathSegments({ message: rule_message, segments: _ }) => rule_message
				}
				failures = if passes {
					[]
				} else {
					[message]
				}
				failures.concat(Plugin.validate_text(value, rest))
			}
		}

	validate_string_list : List(Str), List(StringListRule) -> List(Str)
	validate_string_list = |values, rules|
		match rules {
			[] => []
			[first, .. as rest] => {
				passes = match first {
					AllStrings(rule) => List.all(values, |value| Plugin.validate_text(value, [rule]).is_empty())
					NonemptyStringList(_) => !values.is_empty()
					# A missing first value is covered by NonemptyStringList rather than
					# producing a dependent second failure.
					NonemptyFirstString(_) => values.is_empty() or !(values.first() ?? "").is_empty()
				}
				message = match first {
					AllStrings(rule) => Plugin.text_rule_message(rule)
					NonemptyStringList(rule_message) => rule_message
					NonemptyFirstString(rule_message) => rule_message
				}
				failures = if passes {
					[]
				} else {
					[message]
				}
				failures.concat(Plugin.validate_string_list(values, rest))
			}
		}

	text_rule_message : TextRule -> Str
	text_rule_message = |rule|
		match rule {
			AllBytes({ allowed: _, message }) => message
			BytesInRanges({ excluded: _, message, ranges: _ }) => message
			DisallowedPrefix({ message, prefix: _ }) => message
			DotSeparatedNonemptySegments(message) => message
			ForbiddenPathSegments({ message, segments: _ }) => message
			NonemptyText(message) => message
		}

	byte_matches_any : U8, List(AsciiByte) -> Bool
	byte_matches_any = |byte, allowed|
		List.any(
			allowed,
			|matcher|
				match matcher {
					AsciiUppercase => byte >= 65 and byte <= 90
					AsciiLowercase => byte >= 97 and byte <= 122
					AsciiDigit => byte >= 48 and byte <= 57
					ExactByte(expected) => byte == expected
				},
		)

	validation_message : List(Str) -> Str
	validation_message = |failures| Str.join_with(failures, "\n")

	selector_validation : List(Str) -> Try({}, SelectorDiagnostic)
	selector_validation = |failures|
		if failures.is_empty() {
			Ok({})
		} else {
			Err({ location: None, message: Plugin.validation_message(failures) })
		}

	renderer_validation : List(Str) -> Try({}, RendererDiagnostic)
	renderer_validation = |failures|
		if failures.is_empty() {
			Ok({})
		} else {
			Err({ byte_offset: None, message: Plugin.validation_message(failures) })
		}

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

	ConfigSelection : [
		Missing,
		Selected(LocatedConfigBlock),
		SelectedWithBody({ block : LocatedConfigBlock, body : Body.Shape }),
		SelectedWithRelated(
			{
				block : LocatedConfigBlock,
				body : Body.Shape,
				related_block : LocatedConfigBlock,
				related_body : Body.Shape,
			},
		),
	]

	SelectorDiagnostic := {
		location : [At(SourceLocation), None],
		message : Str,
	}

	ConfigSelector : Str, Command, BackendChoice, List(Str), HostOs, HostArch -> Try(ConfigSelection, SelectorDiagnostic)

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
	select_config = |config_text, command, backend_choice, _, os, _| {
		block_name = match command.config_block {
			OptionalConfigBlock(name) => name
			RequiredConfigBlock(name) => name
		}
		Plugin.select_config_header(config_text, [block_name], backend_choice, os)
	}

	# Select a generic, possibly named block while retaining the standard host
	# fallback and explicit-backend behavior.
	select_config_header : Str, List(Str), BackendChoice, HostOs -> Try(ConfigSelection, SelectorDiagnostic)
	select_config_header = |config_text, header, backend_choice, os| {
		block_header = match backend_choice {
			DefaultBackend(_) => header
			ExplicitBackend(backend) => header.append(backend.name)
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
							SelectedWithBody(selected) => Ok(SelectedWithBody(selected))
							SelectedWithRelated(selected) => Ok(SelectedWithRelated(selected))
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

	RelatedConfig : [
		NoRelatedConfig,
		SelectedRelatedConfig(
			{
				block : LocatedConfigBlock,
				config : Body.Configuration,
			},
		),
	]

	RenderContext := {
		args : List(Str),
		config : Body.Configuration,
		config_block : [NoConfigBlock, SelectedConfigBlock(LocatedConfigBlock)],
		host_arch : HostArch,
		host_os : HostOs,
		related_config : RelatedConfig,
	}

	# Text that will get written to disk.
	# "name" is what our plugin would name
	# the output internally, e.g. "flake",
	# the text is the actual text inside flake.nix
	RenderedOutput := {
		name : Str,
		text : Str,
	}

	PlanRequest := {
		args : List(Str),
		status : Str,
	}

	RenderResult := {
		actions : List(Action),
		outputs : List(RenderedOutput),
		requests : List(PlanRequest),
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

	RegistryDiagnostic := {
		message : Str,
		plugin : Str,
	}

	validate_registry : List(RegistryDefinition) -> Try({}, RegistryDiagnostic)
	validate_registry = |registry|
		match registry {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.validate_definition(first.definition)?
				Plugin.validate_registry(rest)
			}
		}

	validate_definition : Definition -> Try({}, RegistryDiagnostic)
	validate_definition = |definition|
		if definition.commands.is_empty() {
			Plugin.registry_failure(definition.name, "must define at least one command")
		} else if definition.backends.is_empty() {
			Plugin.registry_failure(definition.name, "must define at least one backend")
		} else if definition.implementations.is_empty() {
			Plugin.registry_failure(definition.name, "must define at least one implementation")
		} else {
			Plugin.validate_implementation_references(definition.implementations, definition)?
			Plugin.validate_commands_used(definition.commands, definition.implementations, definition.name)?
			Plugin.validate_backends_used(definition.backends, definition.implementations, definition.name)
		}

	validate_implementation_references : List(Implementation), Definition -> Try({}, RegistryDiagnostic)
	validate_implementation_references = |implementations, definition|
		match implementations {
			[] => Ok({})
			[first, .. as rest] =>
				match Plugin.find_command(definition.commands, first.command) {
					Err(NotFound) => Plugin.registry_failure(definition.name, "implementation '${first.command}/${first.backend}' references unknown command '${first.command}'")
					Ok(_) =>
						match Plugin.find_backend(definition.backends, first.backend) {
							Err(NotFound) => Plugin.registry_failure(definition.name, "implementation '${first.command}/${first.backend}' references unknown backend '${first.backend}'")
							Ok(_) => Plugin.validate_implementation_references(rest, definition)
						}
					}
			}

	validate_commands_used : List(Command), List(Implementation), Str -> Try({}, RegistryDiagnostic)
	validate_commands_used = |commands, implementations, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] =>
				if Plugin.uses_command(implementations, first.name) {
					Plugin.validate_commands_used(rest, implementations, plugin)
				} else {
					Plugin.registry_failure(plugin, "command '${first.name}' has no implementation")
				}
			}

	validate_backends_used : List(Backend), List(Implementation), Str -> Try({}, RegistryDiagnostic)
	validate_backends_used = |backends, implementations, plugin|
		match backends {
			[] => Ok({})
			[first, .. as rest] =>
				if Plugin.uses_backend(implementations, first.name) {
					Plugin.validate_backends_used(rest, implementations, plugin)
				} else {
					Plugin.registry_failure(plugin, "backend '${first.name}' has no implementation")
				}
			}

	uses_command : List(Implementation), Str -> Bool
	uses_command = |implementations, command|
		match implementations {
			[] => Bool.False
			[first, .. as rest] => first.command == command or Plugin.uses_command(rest, command)
		}

	uses_backend : List(Implementation), Str -> Bool
	uses_backend = |implementations, backend|
		match implementations {
			[] => Bool.False
			[first, .. as rest] => first.backend == backend or Plugin.uses_backend(rest, backend)
		}

	registry_failure : Str, Str -> Try({}, RegistryDiagnostic)
	registry_failure = |plugin, message| Err({ message, plugin })

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
		Plugin.plan_registry_nested(registry, config_text, args, os, arch, [], 0)

	plan_registry_nested : List(RegistryDefinition), Str, List(Str), HostOs, HostArch, List(List(Str)), U64 -> Try(Plan, Error)
	plan_registry_nested = |registry, config_text, args, os, arch, ancestors, depth|
		match args {
			[] => Err(UnknownCommand)
			[command_name, .. as command_args] => {
				owner = Plugin.find_owner(registry, command_name)?
				plugin_definition = owner.registry_definition.definition
				command = owner.command
				backend_selection = Plugin.select_backend(plugin_definition.backends, command, command_args) ? |backend_name|
					PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_name, None, "plugin command refers to unknown backend '${backend_name}'"))

				if List.any(ancestors, |ancestor| ancestor == args) {
					Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "plan request cycle detected")))
				} else if depth >= 64 {
					Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "plan request nesting exceeds 64 levels")))
				} else if command.argument_policy == NoArguments and !backend_selection.args.is_empty() {
					Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "command does not accept arguments")))
				} else {
					implementation = Plugin.find_implementation(plugin_definition.implementations, command.name, backend_selection.backend.name) ? |_|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "plugin has no implementation for selected backend"))
					selector = owner.registry_definition.select_config
					selection = selector(config_text, command, backend_selection.choice, backend_selection.args, os, arch) ? |diagnostic|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, diagnostic.location, diagnostic.message))
					parsed = match selection {
						Missing =>
							match command.config_block {
								RequiredConfigBlock(name) => Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "missing required config block '${name}'")))
								OptionalConfigBlock(_) => Ok({ config: Body.empty, config_block: NoConfigBlock, related_config: NoRelatedConfig })
							}
						Selected(block) => {
							config = Body.parse(command.body, block.body) ? |diagnostic|
								PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, At(Plugin.translate_location(block, diagnostic.byte_offset)), Body.describe(diagnostic)))
							Ok({ config, config_block: SelectedConfigBlock(block), related_config: NoRelatedConfig })
						}
						SelectedWithBody({ block, body }) => {
							config = Body.parse(body, block.body) ? |diagnostic|
								PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, At(Plugin.translate_location(block, diagnostic.byte_offset)), Body.describe(diagnostic)))
							Ok({ config, config_block: SelectedConfigBlock(block), related_config: NoRelatedConfig })
						}
						SelectedWithRelated({ block, body, related_block, related_body }) => {
							config = Body.parse(body, block.body) ? |diagnostic|
								PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, At(Plugin.translate_location(block, diagnostic.byte_offset)), Body.describe(diagnostic)))
							related = Body.parse(related_body, related_block.body) ? |diagnostic|
								PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, At(Plugin.translate_location(related_block, diagnostic.byte_offset)), Body.describe(diagnostic)))
							Ok({
								config,
								config_block: SelectedConfigBlock(block),
								related_config: SelectedRelatedConfig({ block: related_block, config: related }),
							})
						}
					}?
					context = Plugin.RenderContext.{
						args: backend_selection.args,
						config: parsed.config,
						config_block: parsed.config_block,
						host_arch: arch,
						host_os: os,
						related_config: parsed.related_config,
					}
					renderer = implementation.renderer
					rendered = renderer(context) ? |diagnostic|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, Plugin.renderer_location(selection, diagnostic.byte_offset), diagnostic.message))
					base_plan = Plugin.lower(implementation, rendered, plugin_definition.name, backend_selection.backend) ? |diagnostic|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, Plugin.renderer_location(selection, diagnostic.byte_offset), diagnostic.message))
					requested = Plugin.plan_requests(
						registry,
						config_text,
						rendered.requests,
						os,
						arch,
						[args].concat(ancestors),
						depth + 1,
					)?
					Ok(
						Plugin.Plan.{
							actions: base_plan.actions.concat(requested.actions),
							backend: base_plan.backend,
							command: base_plan.command,
							plugin: base_plan.plugin,
							requested_packages: base_plan.requested_packages.concat(requested.requested_packages),
						},
					)
				}
			}
		}

	plan_requests : List(RegistryDefinition), Str, List(PlanRequest), HostOs, HostArch, List(List(Str)), U64 -> Try({ actions : List(Action), requested_packages : List(Str) }, Error)
	plan_requests = |registry, config_text, requests, os, arch, ancestors, depth|
		match requests {
			[] => Ok({ actions: [], requested_packages: [] })
			[first, .. as rest] => {
				child = Plugin.plan_registry_nested(registry, config_text, first.args, os, arch, ancestors, depth)?
				remaining = Plugin.plan_requests(registry, config_text, rest, os, arch, ancestors, depth)?
				Ok({
					actions: [PrintLine(first.status)].concat(child.actions).concat(remaining.actions),
					requested_packages: child.requested_packages.concat(remaining.requested_packages),
				})
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
			(Selected(block), At(byte_offset)) => Plugin.relative_location(block, byte_offset)
			(SelectedWithBody({ block, body: _ }), At(byte_offset)) => Plugin.relative_location(block, byte_offset)
			(SelectedWithRelated({ block, body: _, related_block: _, related_body: _ }), At(byte_offset)) => Plugin.relative_location(block, byte_offset)
			_ => None
		}

	relative_location : LocatedConfigBlock, U64 -> [At(SourceLocation), None]
	relative_location = |block, byte_offset|
		if byte_offset <= block.body.to_utf8().len() {
			At(Plugin.translate_location(block, byte_offset))
		} else {
			None
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
				actions: actions.concat(rendered.actions),
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

# -- TESTS --

validation_cases = [
	{
		expected: [],
		rules: [NonemptyText("empty"), DisallowedPrefix({ message: "absolute", prefix: "/" })],
		value: "out",
	},
	{
		expected: ["empty"],
		rules: [NonemptyText("empty"), DisallowedPrefix({ message: "absolute", prefix: "/" })],
		value: "",
	},
	{
		expected: ["absolute", "parent"],
		rules: [
			NonemptyText("empty"),
			DisallowedPrefix({ message: "absolute", prefix: "/" }),
			ForbiddenPathSegments({ message: "parent", segments: [".."] }),
		],
		value: "/../out",
	},
]

expect List.all(
	validation_cases,
	|case| Plugin.validate_text(case.value, case.rules) == case.expected,
)

string_list_validation_cases = [
	{
		expected: [],
		values: ["rocpkgs.nightly", "hello"],
	},
	{
		expected: ["empty"],
		values: ["hello", ""],
	},
	{
		expected: ["segments", "unsafe"],
		values: ["hello$unsafe", "rocpkgs..nightly"],
	},
]

string_list_rules = [
	AllStrings(NonemptyText("empty")),
	AllStrings(DotSeparatedNonemptySegments("segments")),
	AllStrings(BytesInRanges({ excluded: [34, 36, 92], message: "unsafe", ranges: [{ max: 126, min: 33 }] })),
]

expect List.all(
	string_list_validation_cases,
	|case| Plugin.validate_string_list(case.values, string_list_rules) == case.expected,
)

expect Plugin.selector_validation(["first", "second"]) == Err({
	location: None,
	message: "first\nsecond",
})

expect Plugin.renderer_validation(["first", "second"]) == Err({
	byte_offset: None,
	message: "first\nsecond",
})
