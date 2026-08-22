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

	BackendLookup : [QualifiedOnly, QualifiedThenUnqualified]

	ConfigMetadata : [
		DirectConfig(BackendLookup),
		DirectOrNamedConfig(
			{
				block : Str,
				lookup : BackendLookup,
				name_rules : List(TextRule),
			},
		),
		NamedConfig({ lookup : BackendLookup, name_rules : List(TextRule) }),
		NamedWithRelatedConfig(
			{
				lookup : BackendLookup,
				name_rules : List(TextRule),
				related_block : Str,
				related_body : Body.Shape,
				related_field : Str,
			},
		),
	]

	ProjectConfigKind : [DirectProjectConfig, NamedProjectConfig]

	ProjectConfigDescriptor := {
		block : Str,
		body : Body.Shape,
		kind : ProjectConfigKind,
	}

	Command := {
		argument_policy : ArgumentPolicy,
		body : Body.Shape,
		config : ConfigMetadata,
		config_block : ConfigBlockRequirement,
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

	BackendTarget := {
		arch : HostArch,
		os : HostOs,
		value : Str,
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

	ProjectConfigEntry := {
		block : Str,
		config : Body.Configuration,
		header : List(Str),
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

	PlanningDiagnostic := {
		backend : Str,
		command : Str,
		location : [At(SourceLocation), None],
		message : Str,
		plugin : Str,
	}

	# Select config from the command's declarative metadata.
	select_config : ConfigSelector
	select_config = |config_text, command, backend_choice, args, os, _| {
		block_name = Plugin.config_block_name(command.config_block)
		match command.config {
			DirectConfig(lookup) => Plugin.select_with_backend_fallback(config_text, [block_name], backend_choice, os, lookup)
			DirectOrNamedConfig({ block, lookup, name_rules }) =>
				match args {
					[] =>
						match backend_choice {
							DefaultBackend(_) => Plugin.select_config_header(config_text, [block_name], backend_choice, os)
							ExplicitBackend(backend) =>
								match Plugin.select_config_header(config_text, [block, backend.name], DefaultBackend(backend), os)? {
									Missing => Plugin.select_config_header(config_text, [block_name], backend_choice, os)
									Selected(named_block) => Ok(Selected(named_block))
									_ => Err({ location: None, message: "invalid ${block} selection" })
								}
							}
					[name] => Plugin.select_named_config(config_text, block, name, backend_choice, os, lookup, name_rules)
					_ => Err({ location: None, message: "${command.name} accepts at most one config name" })
				}
			NamedConfig({ lookup, name_rules }) =>
				match args {
					[name] => Plugin.select_named_config(config_text, block_name, name, backend_choice, os, lookup, name_rules)
					_ => Err({ location: None, message: "${command.name} requires exactly one config name" })
				}
			NamedWithRelatedConfig({ lookup, name_rules, related_block, related_body, related_field }) =>
				match args {
					[name] => {
						Plugin.selector_validation(Plugin.validate_text(name, name_rules))?
						block = Plugin.select_required_named_block(config_text, block_name, name, backend_choice, os, lookup)?
						config = Plugin.parse_selected_body(command.body, block)?
						related_name = Body.get_string(config, related_field) ? |_|
							{ location: None, message: "validated ${block_name} '${name}' is missing '${related_field}'" }
						related = Plugin.select_required_named_block(config_text, related_block, related_name, backend_choice, os, lookup)?
						Ok(SelectedWithRelated({ block, body: command.body, related_block: related, related_body }))
					}
					_ => Err({ location: None, message: "${command.name} requires exactly one config name" })
				}
			}
	}

	config_block_name : ConfigBlockRequirement -> Str
	config_block_name = |requirement|
		match requirement {
			OptionalConfigBlock(name) => name
			RequiredConfigBlock(name) => name
		}

	config_descriptors : List(Command) -> List(ProjectConfigDescriptor)
	config_descriptors = |commands| Plugin.collect_config_descriptors(commands, [])

	collect_config_descriptors : List(Command), List(ProjectConfigDescriptor) -> List(ProjectConfigDescriptor)
	collect_config_descriptors = |commands, descriptors|
		match commands {
			[] => descriptors
			[first, .. as rest] => {
				with_command = Plugin.append_config_descriptors(
					descriptors,
					Plugin.command_config_descriptors(first),
				)
				Plugin.collect_config_descriptors(rest, with_command)
			}
		}

	command_config_descriptors : Command -> List(ProjectConfigDescriptor)
	command_config_descriptors = |command| {
		config_block = Plugin.config_block_name(command.config_block)
		match command.config {
			DirectConfig(_) => [{ block: config_block, body: command.body, kind: DirectProjectConfig }]
			DirectOrNamedConfig({ block, lookup: _, name_rules: _ }) => [
				{ block: config_block, body: command.body, kind: DirectProjectConfig },
				{ block, body: command.body, kind: NamedProjectConfig },
			]
			NamedConfig(_) => [{ block: config_block, body: command.body, kind: NamedProjectConfig }]
			NamedWithRelatedConfig({ lookup: _, name_rules: _, related_block, related_body, related_field: _ }) => [
				{ block: config_block, body: command.body, kind: NamedProjectConfig },
				{ block: related_block, body: related_body, kind: NamedProjectConfig },
			]
		}
	}

	append_config_descriptors : List(ProjectConfigDescriptor), List(ProjectConfigDescriptor) -> List(ProjectConfigDescriptor)
	append_config_descriptors = |descriptors, additions|
		match additions {
			[] => descriptors
			[first, .. as rest] => {
				already_present = List.any(descriptors, |descriptor| Plugin.same_config_descriptor(descriptor, first))
				updated = if already_present descriptors else descriptors.append(first)
				Plugin.append_config_descriptors(updated, rest)
			}
		}

	same_config_descriptor : ProjectConfigDescriptor, ProjectConfigDescriptor -> Bool
	same_config_descriptor = |left, right|
		left.block == right.block and left.kind == right.kind and Plugin.same_body_shape(left.body, right.body)

	same_body_shape : Body.Shape, Body.Shape -> Bool
	same_body_shape = |left, right|
		match (left, right) {
			(Object(left_fields), Object(right_fields)) => Plugin.same_body_fields(left_fields, right_fields)
		}

	same_body_fields : List(Body.Field), List(Body.Field) -> Bool
	same_body_fields = |left, right|
		match (left, right) {
			([], []) => Bool.True
			([left_field, .. as left_rest], [right_field, .. as right_rest]) =>
				left_field.name == right_field.name and
					left_field.presence == right_field.presence and
						left_field.value == right_field.value and
							Plugin.same_body_fields(left_rest, right_rest)
			_ => Bool.False
		}

	normalize_command_backend : ConfigMetadata, BackendChoice, List(Str) -> { args : List(Str), backend_choice : BackendChoice }
	normalize_command_backend = |metadata, backend_choice, args|
		match metadata {
			NamedConfig(_) | NamedWithRelatedConfig(_) =>
				match (backend_choice, args) {
					(ExplicitBackend(backend), []) => { args: [backend.name], backend_choice: DefaultBackend(backend) }
					_ => { args, backend_choice }
				}
			DirectConfig(_) | DirectOrNamedConfig(_) => { args, backend_choice }
		}

	select_named_config : Str, Str, Str, BackendChoice, HostOs, BackendLookup, List(TextRule) -> Try(ConfigSelection, SelectorDiagnostic)
	select_named_config = |config_text, block_name, name, backend_choice, os, lookup, name_rules| {
		Plugin.selector_validation(Plugin.validate_text(name, name_rules))?
		block = Plugin.select_required_named_block(config_text, block_name, name, backend_choice, os, lookup)?
		Ok(Selected(block))
	}

	select_required_named_block : Str, Str, Str, BackendChoice, HostOs, BackendLookup -> Try(LocatedConfigBlock, SelectorDiagnostic)
	select_required_named_block = |config_text, block_name, name, backend_choice, os, lookup|
		match Plugin.select_with_backend_fallback(config_text, [block_name, name], backend_choice, os, lookup)? {
			Missing => Err({ location: None, message: "missing ${block_name} '${name}'" })
			Selected(block) => Ok(block)
			_ => Err({ location: None, message: "invalid ${block_name} selection" })
		}

	select_with_backend_fallback : Str, List(Str), BackendChoice, HostOs, BackendLookup -> Try(ConfigSelection, SelectorDiagnostic)
	select_with_backend_fallback = |config_text, header, backend_choice, os, lookup| {
		selection = Plugin.select_config_header(config_text, header, backend_choice, os)?
		match (selection, backend_choice, lookup) {
			(Missing, ExplicitBackend(backend), QualifiedThenUnqualified) =>
				Plugin.select_config_header(config_text, header, DefaultBackend(backend), os)
			_ => Ok(selection)
		}
	}

	parse_selected_body : Body.Shape, LocatedConfigBlock -> Try(Body.Configuration, SelectorDiagnostic)
	parse_selected_body = |body, block|
		match Body.parse(body, block.body) {
			Ok(config) => Ok(config)
			Err(diagnostic) => Err({
				location: At(Plugin.translate_location(block, diagnostic.byte_offset)),
				message: Body.describe(diagnostic),
			})
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

	ProjectConfigScope : [HostProjectConfigScope(Config.Block), TopLevelProjectConfigScope]

	build_project_config : Str, List(Command), Str -> Try(List(ProjectConfigEntry), SelectorDiagnostic)
	build_project_config = |config_text, commands, backend| {
		blocks = Config.scan(config_text) ? |diagnostic| {
			location: At(Plugin.source_location(diagnostic.location)),
			message: "invalid plugin configuration",
		}
		Plugin.collect_project_config(
			blocks,
			Plugin.config_descriptors(commands),
			backend,
			TopLevelProjectConfigScope,
			Bool.True,
			[],
			[],
		)
	}

	collect_project_config : List(Config.Block), List(ProjectConfigDescriptor), Str, ProjectConfigScope, Bool, List(List(Str)), List(ProjectConfigEntry) -> Try(List(ProjectConfigEntry), SelectorDiagnostic)
	collect_project_config = |blocks, descriptors, backend, scope, include_hosts, seen, entries|
		match blocks {
			[] => Ok(entries)
			[first, .. as rest] => {
				matching = Plugin.matching_project_descriptors(descriptors, first.header, backend)
				if !matching.is_empty() {
					if seen.contains(first.header) {
						Err({
							location: At(Plugin.project_block_location(first, scope).location),
							message: "duplicate project configuration block",
						})
					} else {
						located = Plugin.project_block_location(first, scope)
						parsed = Plugin.parse_project_descriptors(matching, first.header, located)?
						Plugin.collect_project_config(
							rest,
							descriptors,
							backend,
							scope,
							include_hosts,
							seen.append(first.header),
							entries.concat(parsed),
						)
					}
				} else if include_hosts and Plugin.is_project_host_section(first.header) {
					if seen.contains(first.header) {
						Err({
							location: At(Plugin.source_location(first.location)),
							message: "duplicate host configuration",
						})
					} else {
						nested = Config.scan(first.body) ? |diagnostic| {
							location: At(Plugin.nested_location(first, diagnostic.location)),
							message: "invalid host configuration",
						}
						nested_entries = Plugin.collect_project_config(
							nested,
							descriptors,
							backend,
							HostProjectConfigScope(first),
							Bool.False,
							[],
							[],
						)?
						Plugin.collect_project_config(
							rest,
							descriptors,
							backend,
							scope,
							include_hosts,
							seen.append(first.header),
							entries.concat(nested_entries),
						)
					}
				} else {
					Plugin.collect_project_config(rest, descriptors, backend, scope, include_hosts, seen, entries)
				}
			}
		}

	matching_project_descriptors : List(ProjectConfigDescriptor), List(Str), Str -> List(ProjectConfigDescriptor)
	matching_project_descriptors = |descriptors, header, backend|
		match header {
			[block] => descriptors.keep_if(|descriptor| descriptor.block == block and descriptor.kind == DirectProjectConfig)
			[block, name] =>
				if name == backend {
					direct = descriptors.keep_if(|descriptor| descriptor.block == block and descriptor.kind == DirectProjectConfig)
					if direct.is_empty() {
						descriptors.keep_if(|descriptor| descriptor.block == block and descriptor.kind == NamedProjectConfig)
					} else {
						direct
					}
				} else {
					descriptors.keep_if(|descriptor| descriptor.block == block and descriptor.kind == NamedProjectConfig)
				}
			[block, _, qualifier] =>
				if qualifier == backend {
					descriptors.keep_if(|descriptor| descriptor.block == block and descriptor.kind == NamedProjectConfig)
				} else {
					[]
				}
			_ => []
		}

	is_project_host_section : List(Str) -> Bool
	is_project_host_section = |header| header == ["on", "linux"] or header == ["on", "macos"]

	project_block_location : Config.Block, ProjectConfigScope -> LocatedConfigBlock
	project_block_location = |block, scope|
		match scope {
			TopLevelProjectConfigScope => { body: block.body, location: Plugin.source_location(block.location) }
			HostProjectConfigScope(host) => { body: block.body, location: Plugin.nested_location(host, block.location) }
		}

	parse_project_descriptors : List(ProjectConfigDescriptor), List(Str), LocatedConfigBlock -> Try(List(ProjectConfigEntry), SelectorDiagnostic)
	parse_project_descriptors = |descriptors, header, block|
		match descriptors {
			[] => Ok([])
			[first, .. as rest] => {
				config = Body.parse(first.body, block.body) ? |diagnostic| {
					location: At(Plugin.translate_location(block, diagnostic.byte_offset)),
					message: Body.describe(diagnostic),
				}
				remaining = Plugin.parse_project_descriptors(rest, header, block)?
				Ok(
					[
						{
							block: first.block,
							config,
							header,
							location: block.location,
						},
					].concat(remaining),
				)
			}
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
		project_config : List(ProjectConfigEntry),
		related_config : RelatedConfig,
		target : [NoTarget, SelectedTarget(Str)],
	}

	StringListValidation := {
		field : Body.Field,
		rules : List(StringListRule),
	}

	TargetValidation : [NoTargetValidation, SupportedTargets({ message : Str, supported : List(BackendTarget) })]

	Validator : [
		NoValidation,
		Validate({ string_lists : List(StringListValidation), target : TargetValidation }),
	]

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
		validator : Validator,
	}

	project_configs : RenderContext, List(Str) -> List(ProjectConfigEntry)
	project_configs = |context, block_names|
		context.project_config.keep_if(|entry| block_names.contains(entry.block))

	validate_render_context : RenderContext, Validator -> Try(RenderContext, RendererDiagnostic)
	validate_render_context = |context, validator|
		match validator {
			NoValidation => Ok(context)
			Validate({ string_lists, target }) => {
				selected_target = match target {
					NoTargetValidation => Ok(NoTarget)
					SupportedTargets({ message, supported }) =>
						match Plugin.target_value(supported, context.host_os, context.host_arch) {
							Ok(value) => Ok(SelectedTarget(value))
							Err(_) => Err({ byte_offset: None, message })
						}
					}?
				failures = Plugin.validate_string_list_fields(context.config, string_lists)?
				Plugin.renderer_validation(failures)?
				Ok(
					Plugin.RenderContext.{
						args: context.args,
						config: context.config,
						config_block: context.config_block,
						host_arch: context.host_arch,
						host_os: context.host_os,
						project_config: context.project_config,
						related_config: context.related_config,
						target: selected_target,
					},
				)
			}
		}

	validate_string_list_fields : Body.Configuration, List(StringListValidation) -> Try(List(Str), RendererDiagnostic)
	validate_string_list_fields = |config, validations|
		match validations {
			[] => Ok([])
			[first, .. as rest] => {
				values = Plugin.validated_strings(config, first.field)?
				remaining = Plugin.validate_string_list_fields(config, rest)?
				Ok(Plugin.validate_string_list(values, first.rules).concat(remaining))
			}
		}

	validated_strings : Body.Configuration, Body.Field -> Try(List(Str), RendererDiagnostic)
	validated_strings = |config, field|
		match Body.get_strings(config, field.name) {
			Ok(values) => Ok(values)
			Err(MissingField(_)) if field.presence == Optional => Ok([])
			Err(_) => Err({
				byte_offset: None,
				message: "validated configuration does not match declared field '${field.name}'",
			})
		}

	validated_target : RenderContext -> Try(Str, RendererDiagnostic)
	validated_target = |context|
		match context.target {
			SelectedTarget(value) => Ok(value)
			NoTarget => Err({ byte_offset: None, message: "implementation requires a validated backend target" })
		}

	target_value : List(BackendTarget), HostOs, HostArch -> Try(Str, [UnsupportedPlatform])
	target_value = |supported, os, arch|
		match supported {
			[] => Err(UnsupportedPlatform)
			[first, .. as rest] =>
				if first.os == os and first.arch == arch {
					Ok(first.value)
				} else {
					Plugin.target_value(rest, os, arch)
				}
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

	validate_registry : List(Definition) -> Try({}, RegistryDiagnostic)
	validate_registry = |registry|
		match registry {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.validate_definition(first)?
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
			Plugin.validate_config_descriptors(definition.commands, definition.name)?
			Plugin.validate_implementation_references(definition.implementations, definition)?
			match definition.backends {
				[] => Plugin.registry_failure(definition.name, "must define at least one backend")
				[default_backend, ..] => {
					Plugin.validate_default_implementations(definition.commands, default_backend.name, definition.implementations, definition.name)?
					Plugin.validate_backends_used(definition.backends, definition.implementations, definition.name)
				}
			}
		}

	validate_config_descriptors : List(Command), Str -> Try({}, RegistryDiagnostic)
	validate_config_descriptors = |commands, plugin|
		Plugin.validate_config_descriptor_list(Plugin.config_descriptors_without_deduplication(commands), plugin)

	config_descriptors_without_deduplication : List(Command) -> List(ProjectConfigDescriptor)
	config_descriptors_without_deduplication = |commands|
		match commands {
			[] => []
			[first, .. as rest] => Plugin.command_config_descriptors(first).concat(Plugin.config_descriptors_without_deduplication(rest))
		}

	validate_config_descriptor_list : List(ProjectConfigDescriptor), Str -> Try({}, RegistryDiagnostic)
	validate_config_descriptor_list = |descriptors, plugin|
		match descriptors {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.validate_config_descriptor_against(first, rest, plugin)?
				Plugin.validate_config_descriptor_list(rest, plugin)
			}
		}

	validate_config_descriptor_against : ProjectConfigDescriptor, List(ProjectConfigDescriptor), Str -> Try({}, RegistryDiagnostic)
	validate_config_descriptor_against = |descriptor, remaining, plugin|
		match remaining {
			[] => Ok({})
			[first, .. as rest] =>
				if descriptor.block == first.block and descriptor.kind == first.kind and !Plugin.same_body_shape(descriptor.body, first.body) {
					kind = match descriptor.kind {
						DirectProjectConfig => "direct"
						NamedProjectConfig => "named"
					}
					Plugin.registry_failure(plugin, "${kind} config block '${descriptor.block}' has conflicting body shapes")
				} else {
					Plugin.validate_config_descriptor_against(descriptor, rest, plugin)
				}
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

	validate_default_implementations : List(Command), Str, List(Implementation), Str -> Try({}, RegistryDiagnostic)
	validate_default_implementations = |commands, default_backend, implementations, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] =>
				match Plugin.find_implementation(implementations, first.name, default_backend) {
					Ok(_) => Plugin.validate_default_implementations(rest, default_backend, implementations, plugin)
					Err(NotFound) => Plugin.registry_failure(plugin, "command '${first.name}' has no implementation for default backend '${default_backend}'")
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

	# Plan the first definition that owns the CLI command.
	plan_registry : List(Definition), Str, List(Str), HostOs, HostArch -> Try(Plan, Error)
	plan_registry = |registry, config_text, args, os, arch|
		Plugin.plan_registry_nested(registry, config_text, args, os, arch, [], 0)

	plan_registry_nested : List(Definition), Str, List(Str), HostOs, HostArch, List(List(Str)), U64 -> Try(Plan, Error)
	plan_registry_nested = |registry, config_text, args, os, arch, ancestors, depth|
		match args {
			[] => Err(UnknownCommand)
			[command_name, .. as command_args] => {
				owner = match Plugin.find_owner(registry, command_name) {
					Ok(found) => found
					Err(UnknownCommand) => return Err(UnknownCommand)
				}
				plugin_definition = owner.definition
				command = owner.command
				backend_selection = Plugin.select_backend(plugin_definition.backends, command_args) ? |backend_name|
					PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_name, None, "plugin command refers to unknown backend '${backend_name}'"))
				config_selection = Plugin.normalize_command_backend(command.config, backend_selection.choice, backend_selection.args)

				if List.any(ancestors, |ancestor| ancestor == args) {
					Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "plan request cycle detected")))
				} else if depth >= 64 {
					Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "plan request nesting exceeds 64 levels")))
				} else if command.argument_policy == NoArguments and !backend_selection.args.is_empty() {
					Err(PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "command does not accept arguments")))
				} else {
					implementation = Plugin.find_implementation(plugin_definition.implementations, command.name, backend_selection.backend.name) ? |_|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, None, "plugin has no implementation for selected backend"))
					project_commands = Plugin.effective_commands(registry, command.name)
					project_config = Plugin.build_project_config(config_text, project_commands, backend_selection.backend.name) ? |diagnostic|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, diagnostic.location, diagnostic.message))
					selection = Plugin.select_config(config_text, command, config_selection.backend_choice, config_selection.args, os, arch) ? |diagnostic|
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
						args: config_selection.args,
						config: parsed.config,
						config_block: parsed.config_block,
						host_arch: arch,
						host_os: os,
						project_config,
						related_config: parsed.related_config,
						target: NoTarget,
					}
					validated_context = Plugin.validate_render_context(context, implementation.validator) ? |diagnostic|
						PlanningFailed(Plugin.failure(plugin_definition.name, command.name, backend_selection.backend.name, Plugin.renderer_location(selection, diagnostic.byte_offset), diagnostic.message))
					renderer = implementation.renderer
					rendered = renderer(validated_context) ? |diagnostic|
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

	plan_requests : List(Definition), Str, List(PlanRequest), HostOs, HostArch, List(List(Str)), U64 -> Try({ actions : List(Action), requested_packages : List(Str) }, Error)
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

	effective_commands : List(Definition), Str -> List(Command)
	effective_commands = |registry, owner_command|
		Plugin.find_effective_commands(registry, owner_command, [])

	find_effective_commands : List(Definition), Str, List(Str) -> List(Command)
	find_effective_commands = |registry, owner_command, shadowed|
		match registry {
			[] => []
			[first, .. as rest] =>
				match Plugin.find_command(first.commands, owner_command) {
					Ok(_) => first.commands.keep_if(|command| !shadowed.contains(command.name))
					Err(NotFound) => Plugin.find_effective_commands(rest, owner_command, shadowed.concat(first.commands.map(|command| command.name)))
				}
			}

	find_owner : List(Definition), Str -> Try({ command : Command, definition : Definition }, [UnknownCommand])
	find_owner = |registry, command_name|
		match registry {
			[] => Err(UnknownCommand)
			[first, .. as rest] =>
				match Plugin.find_command(first.commands, command_name) {
					Ok(command) => Ok({ command, definition: first })
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

	select_backend : List(Backend), List(Str) -> Try({ args : List(Str), backend : Backend, choice : BackendChoice }, Str)
	select_backend = |backends, args|
		match args {
			[candidate, .. as rest] =>
				match Plugin.find_backend(backends, candidate) {
					Ok(backend) => Ok({ args: rest, backend, choice: ExplicitBackend(backend) })
					Err(NotFound) => Plugin.select_default_backend(backends, args)
				}
			[] => Plugin.select_default_backend(backends, args)
		}

	select_default_backend : List(Backend), List(Str) -> Try({ args : List(Str), backend : Backend, choice : BackendChoice }, Str)
	select_default_backend = |backends, args|
		match backends {
			[backend, ..] => Ok({ args, backend, choice: DefaultBackend(backend) })
			[] => Err("")
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
		List(ActionTemplate), List(RenderedOutput) -> Try(List(Action), RendererDiagnostic)
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
