# Pure plugin model shared by plugins and the CLI.
import parser.Fields
import parser.Blocks
import Kaifile

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
		BytesInRanges(
			{ excluded : List(U8), message : Str, ranges : List(ByteRange) },
		),
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
					AllBytes({ allowed, message: _ }) =>
						List.all(
							value.to_utf8(),
							|byte| Plugin.byte_matches_any(byte, allowed),
						)
					BytesInRanges({ excluded, message: _, ranges }) =>
						List.all(
							value.to_utf8(),
							|byte|
								List.any(
									ranges,
									|range| byte >= range.min and byte <= range.max,
								) and !excluded.contains(byte),
						)
					# A missing value is covered by NonemptyText rather than producing
					# a dependent second failure.
					DotSeparatedNonemptySegments(_) =>
						value.is_empty() or List.all(
							value.split_on("."),
							|part| !part.is_empty(),
						)
					ForbiddenPathSegments({ message: _, segments }) =>
						!List.any(
							value.split_on("/"),
							|part| List.any(segments, |segment| part == segment),
						)
					}
				message = match first {
					NonemptyText(rule_message) => rule_message
					DisallowedPrefix({ message: rule_message, prefix: _ }) => rule_message
					AllBytes({ allowed: _, message: rule_message }) => rule_message
					BytesInRanges(
						{ excluded: _, message: rule_message, ranges: _ },
					) => rule_message
					DotSeparatedNonemptySegments(rule_message) => rule_message
					ForbiddenPathSegments(
						{ message: rule_message, segments: _ },
					) => rule_message
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
					AllStrings(rule) =>
						List.all(
							values,
							|value| Plugin.validate_text(value, [rule]).is_empty(),
						)
					NonemptyStringList(_) => !values.is_empty()
					# A missing first value is covered by NonemptyStringList rather than
					# producing a dependent second failure.
					NonemptyFirstString(_) =>
						values.is_empty() or !(values.first() ?? "").is_empty()
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

	CommandArgument : [OptionalArgument(Str), RequiredArgument(Str)]

	CommandCall := {
		arguments : List(CommandArgument),
		name : Str,
	}

	call : Str, List(CommandArgument) -> CommandCall
	call = |name, arguments| { arguments, name }

	required_argument : Str -> CommandArgument
	required_argument = |name| RequiredArgument(name)

	optional_argument : Str -> CommandArgument
	optional_argument = |name| OptionalArgument(name)

	KaifileBlock : Kaifile.Block(TextRule)
	KaifileField : Kaifile.Field(TextRule)

	ConfigBlockRequirement : [
		OptionalConfigBlock(KaifileBlock),
		RequiredConfigBlock(KaifileBlock),
	]

	BackendLookup : [QualifiedOnly, QualifiedThenUnqualified]

	ConfigMetadata : [
		DirectConfig(BackendLookup),
		DirectOrNamedConfig(
			{
				argument : Str,
				lookup : BackendLookup,
				named : KaifileBlock,
			},
		),
		NamedConfig({ lookup : BackendLookup }),
		NamedWithRelatedConfig(
			{
				lookup : BackendLookup,
				related : KaifileBlock,
				related_field : Str,
			},
		),
	]

	ProjectConfigDescriptor : KaifileBlock

	Command := {
		call : CommandCall,
		config : ConfigMetadata,
		config_block : ConfigBlockRequirement,
	}

	BackendBlocks : [RequireBackendSpecific]

	command : { call : CommandCall, kaifile : KaifileBlock } -> Command
	command = |declaration|
		Plugin.lower_command(
			declaration.call,
			declaration.kaifile,
			QualifiedThenUnqualified,
		)

	command_with_backend_blocks :
		{
			backend_blocks : BackendBlocks,
			call : CommandCall,
			kaifile : KaifileBlock,
		} -> Command
	command_with_backend_blocks = |declaration| {
		lookup = match declaration.backend_blocks {
			RequireBackendSpecific => QualifiedOnly
		}
		Plugin.lower_command(declaration.call, declaration.kaifile, lookup)
	}

	lower_command : CommandCall, KaifileBlock, BackendLookup -> Command
	lower_command = |command_call, kaifile, lookup|
		match kaifile.selection {
			RequiredBlock =>
				if Kaifile.is_named(kaifile) {
					config = match Kaifile.references(kaifile) {
						[reference, ..] =>
							NamedWithRelatedConfig({
								lookup,
								related: Kaifile.from_reference_target(reference.target),
								related_field: reference.field.name,
							})
						[] => NamedConfig({ lookup: lookup })
					}
					Plugin.Command.{
						call: command_call,
						config,
						config_block: RequiredConfigBlock(kaifile),
					}
				} else {
					Plugin.Command.{
						call: command_call,
						config: DirectConfig(lookup),
						config_block: RequiredConfigBlock(kaifile),
					}
				}
			OptionalBlock =>
				Plugin.Command.{
					call: command_call,
					config: DirectConfig(lookup),
					config_block: OptionalConfigBlock(kaifile),
				}
			ByOptionalArgument({ argument, when_provided }) =>
				Plugin.Command.{
					call: command_call,
					config: DirectOrNamedConfig({
						argument,
						lookup,
						named: Kaifile.from_schema(when_provided),
					}),
					config_block: RequiredConfigBlock(kaifile),
				}
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
		config : Fields.Configuration,
		header : List(Str),
		location : SourceLocation,
	}

	BackendChoice : [DefaultBackend(Backend), ExplicitBackend(Backend)]

	ConfigSelection : [
		Missing,
		Selected(LocatedConfigBlock),
		SelectedWithBody({ block : LocatedConfigBlock, body : Fields.Shape }),
		SelectedWithRelated(
			{
				block : LocatedConfigBlock,
				body : Fields.Shape,
				reference_field : Str,
				related_block : LocatedConfigBlock,
				related_body : Fields.Shape,
			},
		),
	]

	SelectorDiagnostic := {
		location : [At(SourceLocation), None],
		message : Str,
	}

	ConfigSelector :
		Str,
		Command,
		BackendChoice,
		List(Str),
		HostOs,
		HostArch -> Try(
			ConfigSelection,
			SelectorDiagnostic,
		)

	PlanningDiagnostic := {
		backend : Str,
		command : Str,
		location : [At(SourceLocation), None],
		message : Str,
		plugin : Str,
	}

	# Select config from the command's declarative metadata.
	select_config : ConfigSelector
	select_config = |config_text, selected_command, backend_choice, args, os, _| {
		primary = Plugin.config_block_schema(selected_command.config_block)
		block_name = Kaifile.block_name(primary)
		call_name = selected_command.call.name
		match selected_command.config {
			DirectConfig(lookup) =>
				Plugin.select_with_backend_fallback(
					config_text,
					[block_name],
					backend_choice,
					os,
					lookup,
				)
			DirectOrNamedConfig({ argument: _, lookup, named }) => {
				named_block = Kaifile.block_name(named)
				match args {
					[] =>
						match backend_choice {
							DefaultBackend(_) =>
								Plugin.select_config_header(
									config_text,
									[block_name],
									backend_choice,
									os,
								)
							ExplicitBackend(backend) =>
								match Plugin.select_config_header(
									config_text,
									[named_block, backend.name],
									DefaultBackend(backend),
									os,
								)? {
									Missing =>
										Plugin.select_config_header(
											config_text,
											[block_name],
											backend_choice,
											os,
										)
									Selected(block) =>
										Ok(
											SelectedWithBody({
												block,
												body: Kaifile.body(named),
											}),
										)
									_ => Err({
										location: None,
										message: "invalid ${named_block} selection",
									})
								}
							}
					[name] =>
						Plugin.select_named_config(
							config_text,
							named,
							name,
							backend_choice,
							os,
							lookup,
						)
					_ => Err({
						location: None,
						message: "${call_name} accepts at most one config name",
					})
				}
			}
			NamedConfig({ lookup }) =>
				match args {
					[name] =>
						Plugin.select_named_config(
							config_text,
							primary,
							name,
							backend_choice,
							os,
							lookup,
						)
					_ => Err({
						location: None,
						message: "${call_name} requires exactly one config name",
					})
				}
			NamedWithRelatedConfig({ lookup, related, related_field }) =>
				match args {
					[name] => {
						Plugin.selector_validation(
							Plugin.validate_text(name, Kaifile.name_rules(primary)),
						)?
						block = Plugin.select_required_named_block(
							config_text,
							block_name,
							name,
							backend_choice,
							os,
							lookup,
						)?
						body = Kaifile.body(primary)
						config = Plugin.parse_selected_body(body, block)?
						related_name = Fields.get_string(config, related_field) ? |_|
							{
								location: None,
								message: Str.join_with(
									[
										"validated ${block_name} '${name}' is",
										"missing '${related_field}'",
									],
									" ",
								),
							}
						related_block_name = Kaifile.block_name(related)
						related_block = Plugin.select_required_named_block(
							config_text,
							related_block_name,
							related_name,
							backend_choice,
							os,
							lookup,
						)?
						Ok(
							SelectedWithRelated({
								block,
								body,
								reference_field: related_field,
								related_block,
								related_body: Kaifile.body(related),
							}),
						)
					}
					_ => Err({
						location: None,
						message: "${call_name} requires exactly one config name",
					})
				}
			}
	}

	config_block_schema : ConfigBlockRequirement -> KaifileBlock
	config_block_schema = |requirement|
		match requirement {
			OptionalConfigBlock(schema) => schema
			RequiredConfigBlock(schema) => schema
		}

	config_block_name : ConfigBlockRequirement -> Str
	config_block_name = |requirement|
		Kaifile.block_name(Plugin.config_block_schema(requirement))

	config_descriptors : List(Command) -> List(ProjectConfigDescriptor)
	config_descriptors = |commands| Plugin.collect_config_descriptors(commands, [])

	collect_config_descriptors :
		List(Command), List(ProjectConfigDescriptor) -> List(ProjectConfigDescriptor)
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
	command_config_descriptors = |selected_command| {
		primary = Plugin.config_block_schema(selected_command.config_block)
		match selected_command.config {
			DirectConfig(_) | NamedConfig(_) => [primary]
			DirectOrNamedConfig({ argument: _, lookup: _, named }) => [primary, named]
			NamedWithRelatedConfig(
				{
					lookup: _,
					related,
					related_field: _,
				},
			) => [primary, related]
		}
	}

	append_config_descriptors :
		List(ProjectConfigDescriptor),
		List(ProjectConfigDescriptor) -> List(
			ProjectConfigDescriptor,
		)
	append_config_descriptors = |descriptors, additions|
		match additions {
			[] => descriptors
			[first, .. as rest] => {
				already_present = List.any(
					descriptors,
					|descriptor| Plugin.same_config_descriptor(descriptor, first),
				)
				updated = if already_present descriptors else descriptors.append(first)
				Plugin.append_config_descriptors(updated, rest)
			}
		}

	same_config_descriptor :
		ProjectConfigDescriptor, ProjectConfigDescriptor -> Bool
	same_config_descriptor = |left, right|
		Kaifile.block_name(left) == Kaifile.block_name(right) and
			Kaifile.is_named(left) == Kaifile.is_named(right) and
				Plugin.same_body_shape(Kaifile.body(left), Kaifile.body(right))

	same_body_shape : Fields.Shape, Fields.Shape -> Bool
	same_body_shape = |left, right|
		match (left, right) {
			(Object(left_fields), Object(right_fields)) =>
				Plugin.same_body_fields(left_fields, right_fields)
			}

	same_body_fields : List(Fields.Field), List(Fields.Field) -> Bool
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

	normalize_command_backend :
		ConfigMetadata,
		BackendChoice,
		List(Str) -> {
			args : List(Str),
			backend_choice : BackendChoice,
		}
	normalize_command_backend = |metadata, backend_choice, args|
		match metadata {
			NamedConfig(_) | NamedWithRelatedConfig(_) =>
				match (backend_choice, args) {
					(ExplicitBackend(backend), []) => {
						args: [backend.name],
						backend_choice: DefaultBackend(backend),
					}
					_ => { args, backend_choice }
				}
			DirectConfig(_) | DirectOrNamedConfig(_) => { args, backend_choice }
		}

	validate_call_arguments : CommandCall, List(Str) -> Try({}, Str)
	validate_call_arguments = |command_call, args|
		match command_call.arguments {
			[] => if args.is_empty() Ok({}) else Err("command does not accept arguments")
			[OptionalArgument(name)] =>
				match args {
					[] | [_] => Ok({})
					_ => Err("${command_call.name} accepts at most one ${name} argument")
				}
			[RequiredArgument(name)] =>
				match args {
					[_] => Ok({})
					_ => Err("${command_call.name} requires exactly one ${name} argument")
				}
			_ => Err("command declares unsupported arguments")
		}

	select_named_config :
		Str,
		KaifileBlock,
		Str,
		BackendChoice,
		HostOs,
		BackendLookup -> Try(
			ConfigSelection,
			SelectorDiagnostic,
		)
	select_named_config = |text, schema, name, choice, os, lookup| {
		Plugin.selector_validation(
			Plugin.validate_text(name, Kaifile.name_rules(schema)),
		)?
		block = Plugin.select_required_named_block(
			text,
			Kaifile.block_name(schema),
			name,
			choice,
			os,
			lookup,
		)?
		Ok(SelectedWithBody({ block, body: Kaifile.body(schema) }))
	}

	select_required_named_block :
		Str,
		Str,
		Str,
		BackendChoice,
		HostOs,
		BackendLookup -> Try(
			LocatedConfigBlock,
			SelectorDiagnostic,
		)
	select_required_named_block = |text, block, name, choice, os, lookup|
		match Plugin.select_with_backend_fallback(
			text,
			[block, name],
			choice,
			os,
			lookup,
		)? {
			Missing => Err({
				location: None,
				message: "missing ${block} '${name}'",
			})
			Selected(selected) => Ok(selected)
			_ => Err({ location: None, message: "invalid ${block} selection" })
		}

	select_with_backend_fallback :
		Str,
		List(Str),
		BackendChoice,
		HostOs,
		BackendLookup -> Try(
			ConfigSelection,
			SelectorDiagnostic,
		)
	select_with_backend_fallback = |text, header, choice, os, lookup| {
		selection = Plugin.select_config_header(
			text,
			header,
			choice,
			os,
		)?
		match (selection, choice, lookup) {
			(Missing, ExplicitBackend(backend), QualifiedThenUnqualified) =>
				Plugin.select_config_header(
					text,
					header,
					DefaultBackend(backend),
					os,
				)
			_ => Ok(selection)
		}
	}

	parse_selected_body : Fields.Shape,
	LocatedConfigBlock -> Try(
		Fields.Configuration,
		SelectorDiagnostic,
	)
	parse_selected_body = |body, block|
		match Fields.parse(body, block.body) {
			Ok(config) => Ok(config)
			Err(diagnostic) => Err({
				location: At(Plugin.translate_location(block, diagnostic.byte_offset)),
				message: Fields.describe(diagnostic),
			})
		}

	# Select a generic, possibly named block while retaining the standard host
	# fallback and explicit-backend behavior.
	select_config_header :
		Str,
		List(Str),
		BackendChoice,
		HostOs -> Try(
			ConfigSelection,
			SelectorDiagnostic,
		)
	select_config_header = |config_text, header, backend_choice, os| {
		block_header = match backend_choice {
			DefaultBackend(_) => header
			ExplicitBackend(backend) => header.append(backend.name)
		}
		blocks = Blocks.scan(config_text) ? |diagnostic| {
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
				host_selection = Blocks.select_exact(
					blocks,
					["on", section],
				) ? |selection_error|
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

	select_top_level :
		List(Blocks.Block), List(Str) -> Try(ConfigSelection, SelectorDiagnostic)
	select_top_level = |blocks, header| {
		selection = Blocks.select_exact(blocks, header) ? |selection_error|
			Plugin.top_level_duplicate(
				selection_error,
				"duplicate command configuration",
			)
		match selection {
			Missing => Ok(Missing)
			Selected(block) => Ok(
				Selected({
					body: block.body,
					location: Plugin.source_location(block.location),
				}),
			)
		}
	}

	select_nested :
		Blocks.Block, List(Str) -> Try(ConfigSelection, SelectorDiagnostic)
	select_nested = |host, header| {
		blocks = Blocks.scan(host.body) ? |diagnostic| {
			location: At(Plugin.nested_location(host, diagnostic.location)),
			message: "invalid host configuration",
		}
		selection = Blocks.select_exact(blocks, header) ? |selection_error| {
			location = match selection_error {
				DuplicateHeader({ first: _, header: _, second }) =>
					At(Plugin.nested_location(host, second))
				}
			{ location, message: "duplicate command configuration" }
		}
		match selection {
			Missing => Ok(Missing)
			Selected(block) => Ok(
				Selected({
					body: block.body,
					location: Plugin.nested_location(host, block.location),
				}),
			)
		}
	}

	top_level_duplicate : Blocks.SelectionError, Str -> SelectorDiagnostic
	top_level_duplicate = |selection_error, message| {
		location = match selection_error {
			DuplicateHeader({ first: _, header: _, second }) =>
				At(Plugin.source_location(second))
			}
		{ location, message }
	}

	nested_location : Blocks.Block, Blocks.Location -> SourceLocation
	nested_location = |host, location|
		Plugin.translate_location(
			{ body: host.body, location: Plugin.source_location(host.location) },
			location.byte_offset,
		)

	source_location : Blocks.Location -> SourceLocation
	source_location = |location| {
		byte_offset: location.byte_offset,
		column: location.column,
		line: location.line,
	}

	ProjectConfigScope : [
		HostProjectConfigScope(Blocks.Block),
		TopLevelProjectConfigScope,
	]

	build_project_config : Str,
	List(ProjectConfigDescriptor),
	Str -> Try(
		List(ProjectConfigEntry),
		SelectorDiagnostic,
	)
	build_project_config = |config_text, descriptors, backend| {
		blocks = Blocks.scan(config_text) ? |diagnostic| {
			location: At(Plugin.source_location(diagnostic.location)),
			message: "invalid plugin configuration",
		}
		Plugin.collect_project_config(
			blocks,
			descriptors,
			backend,
			TopLevelProjectConfigScope,
			Bool.True,
			[],
			[],
		)
	}

	collect_project_config :
		List(Blocks.Block),
		List(ProjectConfigDescriptor),
		Str,
		ProjectConfigScope,
		Bool,
		List(List(Str)),
		List(ProjectConfigEntry) -> Try(
			List(ProjectConfigEntry),
			SelectorDiagnostic,
		)
	collect_project_config = |blocks, descs, backend, scope, hosts, seen, entries|
		match blocks {
			[] => Ok(entries)
			[first, .. as rest] => {
				matching = Plugin.matching_project_descriptors(
					descs,
					first.header,
					backend,
				)
				if !matching.is_empty() {
					if seen.contains(first.header) {
						Err({
							location: At(Plugin.project_block_location(first, scope).location),
							message: "duplicate project configuration block",
						})
					} else {
						located = Plugin.project_block_location(first, scope)
						Plugin.validate_project_descriptor_shapes(matching, located)?
						parsed = Plugin.parse_project_descriptors(
							matching,
							first.header,
							located,
						)?
						Plugin.collect_project_config(
							rest,
							descs,
							backend,
							scope,
							hosts,
							seen.append(first.header),
							entries.concat(parsed),
						)
					}
				} else if hosts and Plugin.is_project_host_section(first.header) {
					if seen.contains(first.header) {
						Err({
							location: At(Plugin.source_location(first.location)),
							message: "duplicate host configuration",
						})
					} else {
						nested = Blocks.scan(first.body) ? |diagnostic| {
							location: At(Plugin.nested_location(first, diagnostic.location)),
							message: "invalid host configuration",
						}
						nested_entries = Plugin.collect_project_config(
							nested,
							descs,
							backend,
							HostProjectConfigScope(first),
							Bool.False,
							[],
							[],
						)?
						Plugin.collect_project_config(
							rest,
							descs,
							backend,
							scope,
							hosts,
							seen.append(first.header),
							entries.concat(nested_entries),
						)
					}
				} else {
					Plugin.collect_project_config(
						rest,
						descs,
						backend,
						scope,
						hosts,
						seen,
						entries,
					)
				}
			}
		}

	validate_project_descriptor_shapes :
		List(ProjectConfigDescriptor),
		LocatedConfigBlock -> Try(
			{},
			SelectorDiagnostic,
		)
	validate_project_descriptor_shapes = |descriptors, block|
		match descriptors {
			[] => Ok({})
			[first, .. as rest] =>
				if List.all(
					rest,
					|descriptor|
						Plugin.same_body_shape(
							Kaifile.body(first),
							Kaifile.body(descriptor),
						),
				) {
					Ok({})
				} else {
					Err({
						location: At(block.location),
						message: Str.join_with(
							[
								"project config block",
								"'${Kaifile.block_name(first)}' has conflicting",
								"body shapes across plugins",
							],
							" ",
						),
					})
				}
			}

	matching_project_descriptors :
		List(ProjectConfigDescriptor),
		List(Str),
		Str -> List(
			ProjectConfigDescriptor,
		)
	matching_project_descriptors = |descriptors, header, backend|
		match header {
			[block] =>
				descriptors.keep_if(
					|descriptor|
						Kaifile.block_name(descriptor) == block and
							!Kaifile.is_named(descriptor),
				)
			[block, name] =>
				if name == backend {
					direct = descriptors.keep_if(
						|descriptor|
							Kaifile.block_name(descriptor) == block and
								!Kaifile.is_named(descriptor),
					)
					if direct.is_empty() {
						descriptors.keep_if(
							|descriptor|
								Kaifile.block_name(descriptor) == block and
									Kaifile.is_named(descriptor),
						)
					} else {
						direct
					}
				} else {
					descriptors.keep_if(
						|descriptor|
							Kaifile.block_name(descriptor) == block and
								Kaifile.is_named(descriptor),
					)
				}
			[block, _, qualifier] =>
				if qualifier == backend {
					descriptors.keep_if(
						|descriptor|
							Kaifile.block_name(descriptor) == block and
								Kaifile.is_named(descriptor),
					)
				} else {
					[]
				}
			_ => []
		}

	is_project_host_section : List(Str) -> Bool
	is_project_host_section = |header|
		header == ["on", "linux"] or header == ["on", "macos"]

	project_block_location : Blocks.Block, ProjectConfigScope -> LocatedConfigBlock
	project_block_location = |block, scope|
		match scope {
			TopLevelProjectConfigScope => {
				body: block.body,
				location: Plugin.source_location(block.location),
			}
			HostProjectConfigScope(host) => {
				body: block.body,
				location: Plugin.nested_location(host, block.location),
			}
		}

	parse_project_descriptors :
		List(ProjectConfigDescriptor),
		List(Str),
		LocatedConfigBlock -> Try(
			List(ProjectConfigEntry),
			SelectorDiagnostic,
		)
	parse_project_descriptors = |descriptors, header, block|
		match descriptors {
			[] => Ok([])
			[first, .. as rest] => {
				config = Fields.parse(Kaifile.body(first), block.body) ? |diagnostic| {
					location: At(Plugin.translate_location(block, diagnostic.byte_offset)),
					message: Fields.describe(diagnostic),
				}
				remaining = Plugin.parse_project_descriptors(rest, header, block)?
				Ok(
					[
						{
							block: Kaifile.block_name(first),
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
				config : Fields.Configuration,
				field : Str,
			},
		),
	]

	ArtifactAttribute := {
		key : Str,
		value : Str,
	}.{
		encoder_for : _
		parser_for : _
	}

	Artifact := {
		attributes : List(ArtifactAttribute),
		kind : Str,
		name : Str,
		path : Str,
	}.{
		encoder_for : _
		parser_for : _
	}

	RenderContext := {
		args : List(Str),
		config : Fields.Configuration,
		config_block : [NoConfigBlock, SelectedConfigBlock(LocatedConfigBlock)],
		dependencies_resolved : Bool,
		dependency_artifacts : List(Artifact),
		host_arch : HostArch,
		host_os : HostOs,
		project_config : List(ProjectConfigEntry),
		related_config : RelatedConfig,
		target : [NoTarget, SelectedTarget(Str)],
	}

	StringListValidation := {
		field : KaifileField,
		rules : List(StringListRule),
	}

	TargetValidation : [
		NoTargetValidation,
		SupportedTargets(
			{ message : Str, supported : List(BackendTarget) },
		),
	]

	Validator : [
		NoValidation,
		Validate(
			{ string_lists : List(StringListValidation), target : TargetValidation },
		),
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

	same_plan_requests : List(PlanRequest), List(PlanRequest) -> Bool
	same_plan_requests = |left, right|
		match (left, right) {
			([], []) => Bool.True
			([left_first, .. as left_rest], [right_first, .. as right_rest]) =>
				left_first.args == right_first.args and
					left_first.status == right_first.status and
						Plugin.same_plan_requests(left_rest, right_rest)
			_ => Bool.False
		}

	RenderResult := {
		actions : List(Action),
		artifacts : List(Artifact),
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

	reference_config :
		RenderContext, Str -> Try(Fields.Configuration, RendererDiagnostic)
	reference_config = |context, field|
		match context.related_config {
			NoRelatedConfig => Err({
				byte_offset: None,
				message: "validated configuration has no reference field '${field}'",
			})
			SelectedRelatedConfig({ config, field: selected_field }) =>
				if selected_field == field {
					Ok(config)
				} else {
					Err({
						byte_offset: None,
						message: Str.join_with(
							[
								"validated configuration reference field",
								"'${selected_field}' does not match '${field}'",
							],
							" ",
						),
					})
				}
			}

	validate_render_context : RenderContext,
	Validator -> Try(
		RenderContext,
		RendererDiagnostic,
	)
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
						dependencies_resolved: context.dependencies_resolved,
						dependency_artifacts: context.dependency_artifacts,
						host_arch: context.host_arch,
						host_os: context.host_os,
						project_config: context.project_config,
						related_config: context.related_config,
						target: selected_target,
					},
				)
			}
		}

	validate_string_list_fields :
		Fields.Configuration,
		List(StringListValidation) -> Try(
			List(Str),
			RendererDiagnostic,
		)
	validate_string_list_fields = |config, validations|
		match validations {
			[] => Ok([])
			[first, .. as rest] => {
				values = Plugin.validated_strings(config, first.field)?
				remaining = Plugin.validate_string_list_fields(config, rest)?
				Ok(Plugin.validate_string_list(values, first.rules).concat(remaining))
			}
		}

	validated_strings : Fields.Configuration,
	KaifileField -> Try(
		List(Str),
		RendererDiagnostic,
	)
	validated_strings = |config, declared_field| {
		field = Kaifile.parser_field(declared_field)
		match Fields.get_strings(config, field.name) {
			Ok(values) => Ok(values)
			Err(MissingField(_)) if field.presence == Optional => Ok([])
			Err(_) => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"validated configuration does not match declared field",
						"'${field.name}'",
					],
					" ",
				),
			})
		}
	}

	validated_target : RenderContext -> Try(Str, RendererDiagnostic)
	validated_target = |context|
		match context.target {
			SelectedTarget(value) => Ok(value)
			NoTarget => Err({
				byte_offset: None,
				message: "implementation requires a validated backend target",
			})
		}

	target_value : List(BackendTarget),
	HostOs,
	HostArch -> Try(
		Str,
		[UnsupportedPlatform],
	)
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
		project_configs : List(ProjectConfigDescriptor),
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
			Plugin.registry_failure(
				definition.name,
				"must define at least one implementation",
			)
		} else {
			Plugin.validate_command_calls(definition.commands, definition.name)?
			Plugin.validate_command_schemas(definition.commands, definition.name)?
			Plugin.validate_config_descriptors(
				definition.commands,
				definition.project_configs,
				definition.name,
			)?
			Plugin.validate_implementation_references(
				definition.implementations,
				definition,
			)?
			match definition.backends {
				[] =>
					Plugin.registry_failure(
						definition.name,
						"must define at least one backend",
					)
				[default_backend, ..] => {
					Plugin.validate_default_implementations(
						definition.commands,
						default_backend.name,
						definition.implementations,
						definition.name,
					)?
					Plugin.validate_backends_used(
						definition.backends,
						definition.implementations,
						definition.name,
					)
				}
			}
		}

	validate_command_calls : List(Command), Str -> Try({}, RegistryDiagnostic)
	validate_command_calls = |commands, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] =>
				match first.call.arguments {
					[] => Plugin.validate_command_calls(rest, plugin)
					[OptionalArgument(name)] | [RequiredArgument(name)] =>
						if name.is_empty() {
							Plugin.registry_failure(
								plugin,
								Str.join_with(
									[
										"command '${first.call.name}' argument",
										"name must not be empty",
									],
									" ",
								),
							)
						} else {
							Plugin.validate_command_calls(rest, plugin)
						}
					_ =>
						Plugin.registry_failure(
							plugin,
							Str.join_with(
								[
									"command '${first.call.name}' must declare",
									"at most one argument",
								],
								" ",
							),
						)
					}
			}

	validate_command_schemas : List(Command), Str -> Try({}, RegistryDiagnostic)
	validate_command_schemas = |commands, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] => {
				primary = Plugin.config_block_schema(first.config_block)
				match first.config {
					DirectConfig(_) =>
						Plugin.validate_schema_kind(
							primary,
							Bool.False,
							first.call.name,
							plugin,
						)
					DirectOrNamedConfig({ argument, lookup: _, named }) => {
						Plugin.validate_schema_kind(
							primary,
							Bool.False,
							first.call.name,
							plugin,
						)?
						Plugin.validate_schema_kind(
							named,
							Bool.True,
							first.call.name,
							plugin,
						)?
						Plugin.validate_optional_schema_argument(
							first.call,
							argument,
							named,
							plugin,
						)
					}
					NamedConfig(_) => {
						Plugin.validate_schema_kind(
							primary,
							Bool.True,
							first.call.name,
							plugin,
						)?
						Plugin.validate_required_schema_argument(
							first.call,
							primary,
							plugin,
						)
					}
					NamedWithRelatedConfig(
						{
							lookup: _,
							related,
							related_field: _,
						},
					) => {
						Plugin.validate_schema_kind(
							primary,
							Bool.True,
							first.call.name,
							plugin,
						)?
						Plugin.validate_schema_kind(
							related,
							Bool.True,
							first.call.name,
							plugin,
						)?
						Plugin.validate_required_schema_argument(
							first.call,
							primary,
							plugin,
						)
					}
				}?
				Plugin.validate_command_references(first, plugin)?
				Plugin.validate_command_schemas(rest, plugin)
			}
		}

	validate_schema_kind :
		KaifileBlock, Bool, Str, Str -> Try({}, RegistryDiagnostic)
	validate_schema_kind = |schema, expected_named, command_name, plugin| {
		Kaifile.validate_header(schema) ? |message| { message, plugin }
		if Kaifile.is_named(schema) == expected_named {
			Ok({})
		} else {
			expected = if expected_named "named" else "direct"
			Plugin.registry_failure(
				plugin,
				Str.join_with(
					[
						"command '${command_name}' requires a ${expected}",
						"Kaifile block schema",
					],
					" ",
				),
			)
		}
	}

	validate_command_references : Command, Str -> Try({}, RegistryDiagnostic)
	validate_command_references = |selected_command, plugin| {
		primary = Plugin.config_block_schema(selected_command.config_block)
		match selected_command.config {
			DirectConfig(_) | NamedConfig(_) =>
				Plugin.validate_no_reference_fields(
					primary,
					selected_command.call.name,
					plugin,
				)
			DirectOrNamedConfig({ argument: _, lookup: _, named }) => {
				Plugin.validate_no_reference_fields(
					primary,
					selected_command.call.name,
					plugin,
				)?
				Plugin.validate_no_reference_fields(
					named,
					selected_command.call.name,
					plugin,
				)
			}
			NamedWithRelatedConfig({ lookup: _, related, related_field }) =>
				match selected_command.config_block {
					OptionalConfigBlock(_) =>
						Plugin.registry_failure(
							plugin,
							"reference fields require a required Kaifile block",
						)
					RequiredConfigBlock(_) =>
						Plugin.validate_reference_relationship(
							primary,
							related,
							related_field,
							selected_command.call.name,
							plugin,
						)
					}
			}
	}

	validate_no_reference_fields :
		KaifileBlock, Str, Str -> Try({}, RegistryDiagnostic)
	validate_no_reference_fields = |schema, command_name, plugin|
		match Kaifile.references(schema) {
			[] => Ok({})
			[_] =>
				Plugin.registry_failure(
					plugin,
					Str.join_with(
						[
							"command '${command_name}' reference fields require",
							"a required named Kaifile block",
						],
						" ",
					),
				)
			_ => Plugin.reference_count_failure(command_name, plugin)
		}

	validate_reference_relationship :
		KaifileBlock,
		KaifileBlock,
		Str,
		Str,
		Str -> Try(
			{},
			RegistryDiagnostic,
		)
	validate_reference_relationship =
		|primary, related, related_field, command_name, plugin|
			match Kaifile.references(primary) {
				[reference] => {
					field = reference.field
					target = Kaifile.from_reference_target(reference.target)
					if field.presence != Required {
						Plugin.registry_failure(
							plugin,
							"reference field '${field.name}' must be required",
						)
					} else if field.value != Identifier and field.value != String {
						Plugin.registry_failure(
							plugin,
							Str.join_with(
								[
									"reference field '${field.name}' must use",
									"identifier or quoted string syntax",
								],
								" ",
							),
						)
					} else if !Kaifile.is_named(target) {
						Plugin.registry_failure(
							plugin,
							Str.join_with(
								[
									"reference field '${field.name}' must target",
									"a named Kaifile block schema",
								],
								" ",
							),
						)
					} else if reference.target.reference_count > 0 {
						Plugin.registry_failure(
							plugin,
							Str.join_with(
								[
									"reference field '${field.name}' target must not",
									"contain reference fields",
								],
								" ",
							),
						)
					} else if
						field.name != related_field or
							!Plugin.same_config_descriptor(target, related)
							{
								Plugin.registry_failure(
									plugin,
									"command '${command_name}' reference metadata does not match",
								)
							} else {
								Ok({})
							}
				}
				[] =>
					Plugin.registry_failure(
						plugin,
						"command '${command_name}' must declare its reference field",
					)
				_ => Plugin.reference_count_failure(command_name, plugin)
			}

	reference_count_failure : Str, Str -> Try({}, RegistryDiagnostic)
	reference_count_failure = |command_name, plugin|
		Plugin.registry_failure(
			plugin,
			Str.join_with(
				[
					"command '${command_name}' Kaifile block may declare",
					"at most one reference field",
				],
				" ",
			),
		)

	validate_required_schema_argument :
		CommandCall, KaifileBlock, Str -> Try({}, RegistryDiagnostic)
	validate_required_schema_argument = |call_shape, schema, plugin|
		match (call_shape.arguments, Kaifile.header_argument(schema)) {
			([RequiredArgument(argument)], HeaderArgument(slot)) if argument == slot =>
				Ok({})
			_ =>
				Plugin.registry_failure(
					plugin,
					Str.join_with(
						[
							"command '${call_shape.name}' must declare one required",
							"argument matching its Kaifile header slot",
						],
						" ",
					),
				)
			}

	validate_optional_schema_argument :
		CommandCall, Str, KaifileBlock, Str -> Try({}, RegistryDiagnostic)
	validate_optional_schema_argument =
		|call_shape, selected_argument, schema, plugin| {
			failure = |_|
				Plugin.registry_failure(
					plugin,
					Str.join_with(
						[
							"command '${call_shape.name}' must use one optional",
							"argument matching its Kaifile header slot",
						],
						" ",
					),
				)
			match (call_shape.arguments, Kaifile.header_argument(schema)) {
				([OptionalArgument(argument)], HeaderArgument(slot)) =>
					if argument == selected_argument and argument == slot {
						Ok({})
					} else {
						failure({})
					}
				_ => failure({})
			}
		}

	validate_config_descriptors :
		List(Command),
		List(ProjectConfigDescriptor),
		Str -> Try(
			{},
			RegistryDiagnostic,
		)
	validate_config_descriptors = |commands, standalone_descriptors, plugin|
		Plugin.validate_config_descriptor_list(
			Plugin.config_descriptors_without_deduplication(commands).concat(
				standalone_descriptors,
			),
			plugin,
		)

	config_descriptors_without_deduplication : List(Command) -> List(
		ProjectConfigDescriptor,
	)
	config_descriptors_without_deduplication = |commands|
		match commands {
			[] => []
			[first, .. as rest] =>
				Plugin.command_config_descriptors(first).concat(
					Plugin.config_descriptors_without_deduplication(rest),
				)
			}

	validate_config_descriptor_list : List(ProjectConfigDescriptor),
	Str -> Try(
		{},
		RegistryDiagnostic,
	)
	validate_config_descriptor_list = |descriptors, plugin|
		match descriptors {
			[] => Ok({})
			[first, .. as rest] => {
				Kaifile.validate_header(first) ? |message| { message, plugin }
				Plugin.validate_config_descriptor_against(first, rest, plugin)?
				Plugin.validate_config_descriptor_list(rest, plugin)
			}
		}

	validate_config_descriptor_against :
		ProjectConfigDescriptor,
		List(ProjectConfigDescriptor),
		Str -> Try(
			{},
			RegistryDiagnostic,
		)
	validate_config_descriptor_against = |descriptor, remaining, plugin|
		match remaining {
			[] => Ok({})
			[first, .. as rest] =>
				if
					Kaifile.block_name(descriptor) == Kaifile.block_name(first) and
						Kaifile.is_named(descriptor) == Kaifile.is_named(first) and
							!Plugin.same_body_shape(
								Kaifile.body(descriptor),
								Kaifile.body(first),
							)
						{
							kind = if Kaifile.is_named(descriptor) "named" else "direct"
							Plugin.registry_failure(
								plugin,
								Str.join_with(
									[
										"${kind} config block",
										"'${Kaifile.block_name(descriptor)}' has",
										"conflicting body shapes",
									],
									" ",
								),
							)
						} else {
							Plugin.validate_config_descriptor_against(descriptor, rest, plugin)
						}
			}

	validate_implementation_references : List(Implementation),
	Definition -> Try(
		{},
		RegistryDiagnostic,
	)
	validate_implementation_references = |implementations, definition|
		match implementations {
			[] => Ok({})
			[first, .. as rest] =>
				match Plugin.find_command(definition.commands, first.command) {
					Err(NotFound) =>
						Plugin.registry_failure(
							definition.name,
							Str.join_with(
								[
									"implementation '${first.command}/${first.backend}'",
									"references unknown command '${first.command}'",
								],
								" ",
							),
						)
					Ok(_) =>
						match Plugin.find_backend(definition.backends, first.backend) {
							Err(NotFound) =>
								Plugin.registry_failure(
									definition.name,
									Str.join_with(
										[
											"implementation '${first.command}/${first.backend}'",
											"references unknown backend '${first.backend}'",
										],
										" ",
									),
								)
							Ok(_) => Plugin.validate_implementation_references(rest, definition)
						}
					}
			}

	validate_default_implementations :
		List(Command),
		Str,
		List(Implementation),
		Str -> Try(
			{},
			RegistryDiagnostic,
		)
	validate_default_implementations = |commands, backend, implementations, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] =>
				match Plugin.find_implementation(
					implementations,
					first.call.name,
					backend,
				) {
					Ok(_) =>
						Plugin.validate_default_implementations(
							rest,
							backend,
							implementations,
							plugin,
						)
					Err(NotFound) =>
						Plugin.registry_failure(
							plugin,
							Str.join_with(
								[
									"command '${first.call.name}' has no",
									"implementation for default backend",
									"'${backend}'",
								],
								" ",
							),
						)
					}
			}

	validate_backends_used : List(Backend),
	List(Implementation),
	Str -> Try(
		{},
		RegistryDiagnostic,
	)
	validate_backends_used = |backends, implementations, plugin|
		match backends {
			[] => Ok({})
			[first, .. as rest] =>
				if Plugin.uses_backend(implementations, first.name) {
					Plugin.validate_backends_used(rest, implementations, plugin)
				} else {
					Plugin.registry_failure(
						plugin,
						"backend '${first.name}' has no implementation",
					)
				}
			}

	uses_backend : List(Implementation), Str -> Bool
	uses_backend = |implementations, backend|
		match implementations {
			[] => Bool.False
			[first, .. as rest] =>
				first.backend == backend or Plugin.uses_backend(rest, backend)
			}

	registry_failure : Str, Str -> Try({}, RegistryDiagnostic)
	registry_failure = |plugin, message| Err({ message, plugin })

	Plan := {
		actions : List(Action),
		artifacts : List(Artifact),
		backend : Backend,
		command : Str,
		plugin : Str,
		requested_packages : List(Str),
	}.{
		encoder_for : _
		parser_for : _
	}

	# Plan the first definition that owns the CLI command.
	plan_registry : List(Definition),
	Str,
	List(Str),
	HostOs,
	HostArch -> Try(
		Plan,
		Error,
	)
	plan_registry = |registry, config_text, args, os, arch|
		Plugin.plan_registry_nested(registry, config_text, args, os, arch, [], 0)

	plan_registry_nested :
		List(Definition),
		Str,
		List(Str),
		HostOs,
		HostArch,
		List(List(Str)),
		U64 -> Try(
			Plan,
			Error,
		)
	plan_registry_nested =
		|registry, config_text, args, os, arch, ancestors, depth|
			match args {
				[] => Err(UnknownCommand)
				[command_name, .. as command_args] => {
					owner = match Plugin.find_owner(registry, command_name) {
						Ok(found) => found
						Err(UnknownCommand) => return Err(UnknownCommand)
					}
					plugin_definition = owner.definition
					selected_command = owner.command
					plugin = plugin_definition.name
					call_name = selected_command.call.name
					backend_selection = Plugin.select_backend(
						plugin_definition.backends,
						command_args,
					) ? |backend_name|
						PlanningFailed(
							Plugin.failure(
								plugin,
								call_name,
								backend_name,
								None,
								Str.join_with(
									[
										"plugin command refers to unknown backend",
										"'${backend_name}'",
									],
									" ",
								),
							),
						)
					backend = backend_selection.backend
					config_selection = Plugin.normalize_command_backend(
						selected_command.config,
						backend_selection.choice,
						backend_selection.args,
					)
					fail = |location, message|
						PlanningFailed(
							Plugin.failure(
								plugin,
								call_name,
								backend.name,
								location,
								message,
							),
						)

					if List.any(ancestors, |ancestor| ancestor == args) {
						Err(fail(None, "plan request cycle detected"))
					} else if depth >= 64 {
						Err(fail(None, "plan request nesting exceeds 64 levels"))
					} else {
						Plugin.validate_call_arguments(
							selected_command.call,
							config_selection.args,
						) ? |message| fail(None, message)
						implementation = Plugin.find_implementation(
							plugin_definition.implementations,
							call_name,
							backend.name,
						) ? |_|
							fail(
								None,
								"plugin has no implementation for selected backend",
							)
						project_commands = Plugin.effective_commands(registry)
						project_descriptors = Plugin.append_config_descriptors(
							Plugin.config_descriptors(project_commands),
							Plugin.effective_project_configs(registry),
						)
						project_config = Plugin.build_project_config(
							config_text,
							project_descriptors,
							backend.name,
						) ? |diagnostic|
							fail(diagnostic.location, diagnostic.message)
						selection = Plugin.select_config(
							config_text,
							selected_command,
							config_selection.backend_choice,
							config_selection.args,
							os,
							arch,
						) ? |diagnostic|
							fail(diagnostic.location, diagnostic.message)
						parsed = match selection {
							Missing =>
								match selected_command.config_block {
									RequiredConfigBlock(schema) =>
										Err(
											fail(
												None,
												Str.join_with(
													[
														"missing required config block",
														"'${Kaifile.block_name(schema)}'",
													],
													" ",
												),
											),
										)
									OptionalConfigBlock(_) => Ok({
										config: Fields.empty,
										config_block: NoConfigBlock,
										related_config: NoRelatedConfig,
									})
								}
							Selected(block) => {
								config = Fields.parse(
									Kaifile.body(
										Plugin.config_block_schema(
											selected_command.config_block,
										),
									),
									block.body,
								) ? |diagnostic|
									fail(
										At(
											Plugin.translate_location(
												block,
												diagnostic.byte_offset,
											),
										),
										Fields.describe(diagnostic),
									)
								Ok({
									config,
									config_block: SelectedConfigBlock(block),
									related_config: NoRelatedConfig,
								})
							}
							SelectedWithBody({ block, body }) => {
								config = Fields.parse(body, block.body) ? |diagnostic|
									fail(
										At(
											Plugin.translate_location(
												block,
												diagnostic.byte_offset,
											),
										),
										Fields.describe(diagnostic),
									)
								Ok({
									config,
									config_block: SelectedConfigBlock(block),
									related_config: NoRelatedConfig,
								})
							}
							SelectedWithRelated(
								{
									block,
									body,
									reference_field,
									related_block,
									related_body,
								},
							) => {
								config = Fields.parse(body, block.body) ? |diagnostic|
									fail(
										At(
											Plugin.translate_location(
												block,
												diagnostic.byte_offset,
											),
										),
										Fields.describe(diagnostic),
									)
								related = Fields.parse(
									related_body,
									related_block.body,
								) ? |diagnostic|
									fail(
										At(
											Plugin.translate_location(
												related_block,
												diagnostic.byte_offset,
											),
										),
										Fields.describe(diagnostic),
									)
								Ok({
									config,
									config_block: SelectedConfigBlock(block),
									related_config: SelectedRelatedConfig({
										config: related,
										field: reference_field,
									}),
								})
							}
						}?
						context = Plugin.RenderContext.{
							args: config_selection.args,
							config: parsed.config,
							config_block: parsed.config_block,
							dependencies_resolved: Bool.False,
							dependency_artifacts: [],
							host_arch: arch,
							host_os: os,
							project_config,
							related_config: parsed.related_config,
							target: NoTarget,
						}
						renderer_fail = |diagnostic|
							fail(
								Plugin.renderer_location(
									selection,
									diagnostic.byte_offset,
								),
								diagnostic.message,
							)
						validated_context = Plugin.validate_render_context(
							context,
							implementation.validator,
						) ? |diagnostic| renderer_fail(diagnostic)
						renderer = implementation.renderer
						initial_render = renderer(validated_context) ? |diagnostic|
							renderer_fail(diagnostic)
						requested = Plugin.plan_requests(
							registry,
							config_text,
							initial_render.requests,
							os,
							arch,
							[args].concat(ancestors),
							depth + 1,
							plugin,
							call_name,
							backend.name,
						)?
						rendered = if initial_render.requests.is_empty() {
							initial_render
						} else {
							with_dependencies = renderer(
								Plugin.RenderContext.{
									args: validated_context.args,
									config: validated_context.config,
									config_block: validated_context.config_block,
									dependencies_resolved: Bool.True,
									dependency_artifacts: requested.artifacts,
									host_arch: validated_context.host_arch,
									host_os: validated_context.host_os,
									project_config: validated_context.project_config,
									related_config: validated_context.related_config,
									target: validated_context.target,
								},
							) ? |diagnostic| renderer_fail(diagnostic)
							if Plugin.same_plan_requests(
								with_dependencies.requests,
								initial_render.requests,
							) {
								with_dependencies
							} else {
								return Err(
									fail(
										None,
										Str.join_with(
											[
												"plan requests changed after",
												"dependencies resolved",
											],
											" ",
										),
									),
								)
							}
						}
						base_plan = Plugin.lower(
							implementation,
							rendered,
							plugin,
							backend,
						) ? |diagnostic| renderer_fail(diagnostic)
						Ok(
							Plugin.Plan.{
								actions: requested.actions.concat(base_plan.actions),
								artifacts: requested.artifacts.concat(base_plan.artifacts),
								backend: base_plan.backend,
								command: base_plan.command,
								plugin: base_plan.plugin,
								requested_packages: requested.requested_packages.concat(
									base_plan.requested_packages,
								),
							},
						)
					}
				}
			}

	plan_requests :
		List(Definition),
		Str,
		List(PlanRequest),
		HostOs,
		HostArch,
		List(List(Str)),
		U64,
		Str,
		Str,
		Str -> Try(
			{
				actions : List(Action),
				artifacts : List(Artifact),
				requested_packages : List(Str),
			},
			Error,
		)
	plan_requests = |defs, text, reqs, os, arch, parents, depth, plugin, cmd, back|
		match reqs {
			[] => Ok({ actions: [], artifacts: [], requested_packages: [] })
			[first, .. as rest] => {
				child = Plugin.plan_registry_nested(
					defs,
					text,
					first.args,
					os,
					arch,
					parents,
					depth,
				) ? |error|
					match error {
						UnknownCommand => PlanningFailed(
							Plugin.failure(
								plugin,
								cmd,
								back,
								None,
								Str.join_with(
									[
										"plan request refers to unknown command",
										"'${first.args.first() ?? ""}'",
									],
									" ",
								),
							),
						)
						PlanningFailed(diagnostic) => PlanningFailed(diagnostic)
					}
				remaining = Plugin.plan_requests(
					defs,
					text,
					rest,
					os,
					arch,
					parents,
					depth,
					plugin,
					cmd,
					back,
				)?
				Ok({
					actions: [PrintLine(first.status)].concat(child.actions).concat(
						remaining.actions,
					),
					artifacts: child.artifacts.concat(remaining.artifacts),
					requested_packages: child.requested_packages.concat(
						remaining.requested_packages,
					),
				})
			}
		}

	effective_commands : List(Definition) -> List(Command)
	effective_commands = |registry| Plugin.find_effective_commands(registry, [])

	find_effective_commands : List(Definition), List(Str) -> List(Command)
	find_effective_commands = |registry, shadowed|
		match registry {
			[] => []
			[first, .. as rest] => {
				effective = first.commands.keep_if(
					|candidate| !shadowed.contains(candidate.call.name),
				)
				effective.concat(
					Plugin.find_effective_commands(
						rest,
						shadowed.concat(
							first.commands.map(|candidate| candidate.call.name),
						),
					),
				)
			}
		}

	effective_project_configs : List(Definition) -> List(ProjectConfigDescriptor)
	effective_project_configs = |registry|
		match registry {
			[] => []
			[first, .. as rest] =>
				Plugin.append_config_descriptors(
					first.project_configs,
					Plugin.effective_project_configs(rest),
				)
			}

	find_owner : List(Definition),
	Str -> Try(
		{ command : Command, definition : Definition },
		[UnknownCommand],
	)
	find_owner = |registry, command_name|
		match registry {
			[] => Err(UnknownCommand)
			[first, .. as rest] =>
				match Plugin.find_command(first.commands, command_name) {
					Ok(found_command) => Ok({
						command: found_command,
						definition: first,
					})
					Err(NotFound) => Plugin.find_owner(rest, command_name)
				}
			}

	find_command : List(Command), Str -> Try(Command, [NotFound])
	find_command = |commands, name|
		match commands {
			[] => Err(NotFound)
			[first, .. as rest] =>
				if first.call.name == name {
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

	select_backend : List(Backend),
	List(Str) -> Try(
		{ args : List(Str), backend : Backend, choice : BackendChoice },
		Str,
	)
	select_backend = |backends, args|
		match args {
			[candidate, .. as rest] =>
				match Plugin.find_backend(backends, candidate) {
					Ok(backend) => Ok({
						args: rest,
						backend,
						choice: ExplicitBackend(backend),
					})
					Err(NotFound) => Plugin.select_default_backend(backends, args)
				}
			[] => Plugin.select_default_backend(backends, args)
		}

	select_default_backend : List(Backend),
	List(Str) -> Try(
		{ args : List(Str), backend : Backend, choice : BackendChoice },
		Str,
	)
	select_default_backend = |backends, args|
		match backends {
			[backend, ..] => Ok({ args, backend, choice: DefaultBackend(backend) })
			[] => Err("")
		}

	find_implementation : List(Implementation),
	Str,
	Str -> Try(
		Implementation,
		[NotFound],
	)
	find_implementation = |implementations, command_name, backend|
		match implementations {
			[] => Err(NotFound)
			[first, .. as rest] =>
				if first.command == command_name and first.backend == backend {
					Ok(first)
				} else {
					Plugin.find_implementation(rest, command_name, backend)
				}
			}

	failure : Str, Str, Str, [At(SourceLocation), None], Str -> PlanningDiagnostic
	failure = |plugin, command_name, backend, location, message|
		{ backend, command: command_name, location, message, plugin }

	renderer_location : ConfigSelection,
	[At(U64), None] -> [
		At(SourceLocation),
		None,
	]
	renderer_location = |selection, relative|
		match (selection, relative) {
			(Selected(block), At(byte_offset)) =>
				Plugin.relative_location(block, byte_offset)
			(
				SelectedWithBody({ block, body: _ }),
				At(byte_offset),
			) => Plugin.relative_location(block, byte_offset)
			(
				SelectedWithRelated(
					{
						block,
						body: _,
						reference_field: _,
						related_block: _,
						related_body: _,
					},
				),
				At(byte_offset),
			) => Plugin.relative_location(block, byte_offset)
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
			Plugin.translate_bytes(
				bytes,
				target,
				index + 1,
				{
					byte_offset: location.byte_offset,
					column: 1,
					line: location.line + 1,
				},
			)
		} else {
			Plugin.translate_bytes(
				bytes,
				target,
				index + 1,
				{
					byte_offset: location.byte_offset,
					column: location.column + 1,
					line: location.line,
				},
			)
		}

	# Convert pure action templates into a runtime plan.
	lower : Implementation,
	RenderResult,
	Str,
	Backend -> Try(
		Plan,
		RendererDiagnostic,
	)
	lower = |implementation, rendered, plugin, backend| {
		actions = Plugin.lower_actions(
			implementation.actions,
			rendered.outputs,
		)?
		Ok(
			Plugin.Plan.{
				actions: actions.concat(rendered.actions),
				artifacts: rendered.artifacts,
				backend,
				command: implementation.command,
				plugin,
				requested_packages: rendered.requested_packages,
			},
		)
	}

	lower_actions :
		List(ActionTemplate),
		List(RenderedOutput) -> Try(
			List(Action),
			RendererDiagnostic,
		)
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
