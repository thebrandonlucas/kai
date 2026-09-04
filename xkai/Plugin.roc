# Pure plugin model shared by plugins and the CLI.
import parser.Fields
import parser.Blocks
import Kaifile

Plugin := [].{
	Error : [
		InvalidWorkspaceRoot(Str),
		PlanningFailed(PlanningDiagnostic),
		UnknownCommand,
	]
	HostOs : [LINUX, MACOS, OTHER(Str)]
	HostArch : [X86, X64, ARM, AARCH64, OTHER(Str)]

	default_workspace_root : Str
	default_workspace_root = ".kai"

	workspace_path : Str, Str -> Str
	workspace_path = |workspace_root, path| "${workspace_root}/${path}"

	# Side effects to be performed later by the executor.
	ExecutionStep := [
		PrintLine(Str),
		RunProgram({ arguments : List(Str), program : Str }),
		WriteFile({ contents : Str, path : Str }),
	].{
		encoder_for : _
		parser_for : _
	}

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

	workspace_root_rules : List(TextRule)
	workspace_root_rules = [
		NonemptyText("KAI_DIR must not be empty"),
		ForbiddenPathSegments({
			message: "KAI_DIR must not be '.' or '..'",
			segments: [".", ".."],
		}),
		DisallowedPrefix({
			message: "KAI_DIR must not start with '-'",
			prefix: "-",
		}),
		AllBytes({
			allowed: [
				AsciiUppercase,
				AsciiLowercase,
				AsciiDigit,
				ExactByte('.'),
				ExactByte('_'),
				ExactByte('-'),
			],
			message: Str.join_with(
				[
					"KAI_DIR must be one relative top-level directory name ",
					"containing only ASCII letters, digits, '.', '_', and '-'",
				],
				"",
			),
		}),
	]

	validate_workspace_root : Str -> Try({}, Str)
	validate_workspace_root = |workspace_root| {
		failures = Plugin.validate_text(workspace_root, workspace_root_rules)
		normalized = Str.from_utf8_lossy(
			Str.to_utf8(workspace_root).map(|byte|
				if byte >= 65 and byte <= 90 byte + 32 else byte),
		)
		reserved_roots = [
			".bzr",
			".git",
			".hg",
			".jj",
			".svn",
			"_darcs",
			"cvs",
			"kai.lock",
			"kaifile",
		]
		if normalized == Plugin.default_workspace_root and
			workspace_root != Plugin.default_workspace_root {
			Err("invalid workspace root: use the canonical '.kai' spelling")
		} else if reserved_roots.contains(normalized) {
			Err("invalid workspace root: KAI_DIR is reserved")
		} else if failures.is_empty() {
			Ok({})
		} else {
			Err("invalid workspace root: ${Plugin.validation_message(failures)}")
		}
	}

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

	implementation_validation : List(Str) -> Try({}, BackendPlanningDiagnostic)
	implementation_validation = |failures|
		if failures.is_empty() {
			Ok({})
		} else {
			Err({ byte_offset: None, message: Plugin.validation_message(failures) })
		}

	CommandArgument : [OptionalArgument(Str), RequiredArgument(Str)]

	CommandHelpArgument := {
		description : Str,
		name : Str,
		presence : [OptionalHelpArgument, RequiredHelpArgument],
	}

	CommandHelp := {
		arguments : List(CommandHelpArgument),
		description : Str,
		examples : List(Str),
		kaifile_block_example : [
			KaifileBlockExample(List(Str)),
			NoKaifileBlockExample,
		],
	}

	CommandHelpAvailability : [CommandHelpAvailable(CommandHelp), NoCommandHelp]

	CommandSyntax := {
		arguments : List(CommandArgument),
		help : CommandHelpAvailability,
		name : Str,
	}

	command_syntax : Str, List(CommandArgument) -> CommandSyntax
	command_syntax = |name, arguments| { arguments, help: NoCommandHelp, name }

	command_syntax_with_help :
		Str, List(CommandArgument), CommandHelp -> CommandSyntax
	command_syntax_with_help = |name, arguments, help|
		{ arguments, help: CommandHelpAvailable(help), name }

	required_argument : Str -> CommandArgument
	required_argument = |name| RequiredArgument(name)

	optional_argument : Str -> CommandArgument
	optional_argument = |name| OptionalArgument(name)

	Block : Kaifile.Block(TextRule)
	KaifileField : Kaifile.Field(TextRule)

	ExplicitBackendBlock : [RequireBackendBlock, TryBackendThenShared]

	Command : [
		CommandOnly(CommandSyntax),
		CommandWithBlock(
			{
				block : Block,
				syntax : CommandSyntax,
				explicit_backend_block : ExplicitBackendBlock,
			},
		),
	]

	Schema := {
		blocks : List(Block),
		commands : List(Command),
	}

	command_only : CommandSyntax -> Command
	command_only = |declared_command| CommandOnly(declared_command)

	command_with_block :
		{ block : Block, syntax : CommandSyntax } -> Command
	command_with_block = |declaration|
		CommandWithBlock({
			block: declaration.block,
			syntax: declaration.syntax,
			explicit_backend_block: TryBackendThenShared,
		})

	command_with_required_backend_block :
		{ block : Block, syntax : CommandSyntax } -> Command
	command_with_required_backend_block = |declaration|
		CommandWithBlock({
			block: declaration.block,
			syntax: declaration.syntax,
			explicit_backend_block: RequireBackendBlock,
		})

	syntax_from_command : Command -> CommandSyntax
	syntax_from_command = |command|
		match command {
			CommandOnly(declared_command) => declared_command
			CommandWithBlock(declaration) => declaration.syntax
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
		prompt : [DefaultPrompt, Prompt(Str)],
		steps : List(ExecutionStep),
	}

	Backend := {
		determinate_system : DeterminateSystem,
		fallback : [Fallback(Fallback), NoFallback],
		name : Str,
		required_packages : List(Package),
	}

	SupportedBackendTarget := {
		arch : HostArch,
		os : HostOs,
		value : Str,
	}

	Host := {
		arch : HostArch,
		os : HostOs,
	}

	SourceLocation := {
		byte_offset : U64,
		column : U64,
		line : U64,
	}.{
		is_eq : SourceLocation, SourceLocation -> Bool
		is_eq = |left, right|
			left.byte_offset == right.byte_offset and
				left.column == right.column and
					left.line == right.line
	}

	# location is absolute within the complete Kaifile text, including when a
	# plugin selects a block nested inside another generic block.
	LocatedBlock := {
		body : Str,
		location : SourceLocation,
	}

	ParsedBlock := {
		fields : Fields.ParsedFields,
		header : List(Str),
		kind : Str,
		location : SourceLocation,
	}

	BackendChoice : [DefaultBackend(Backend), ExplicitBackend(Backend)]

	BlockSelection : [
		Missing,
		Selected(LocatedBlock),
		SelectedWithReference(
			{
				reference_field : Str,
				referenced_block : LocatedBlock,
				selected_block : LocatedBlock,
			},
		),
	]

	SelectorDiagnostic := {
		location : [At(SourceLocation), None],
		message : Str,
	}

	BlockSelector :
		Str,
		List(ParsedBlock),
		Command,
		BackendChoice,
		List(Str),
		HostOs,
		HostArch -> Try(
			BlockSelection,
			SelectorDiagnostic,
		)

	PlanningDiagnostic := {
		backend : Str,
		command : Str,
		location : [At(SourceLocation), None],
		message : Str,
		plugin : Str,
	}.{
		is_eq : PlanningDiagnostic, PlanningDiagnostic -> Bool
		is_eq = |left, right|
			left.backend == right.backend and
				left.command == right.command and
					left.location == right.location and
						left.message == right.message and
							left.plugin == right.plugin
	}

	# Select a Kaifile block for the command.
	select_command_block : BlockSelector
	select_command_block = |text, blocks, command, choice, args, os, _|
		match command {
			CommandOnly(_) => Ok(Missing)
			CommandWithBlock(
				{
					block: primary,
					syntax: declared_command,
					explicit_backend_block,
				},
			) => {
				block_name = Kaifile.block_name(primary)
				command_name = declared_command.name
				match primary.selection {
					RequiredBlock =>
						if Kaifile.is_named(primary) {
							match (args, Kaifile.references(primary)) {
								([name], [reference, ..]) => {
									Plugin.selector_validation(
										Plugin.validate_text(name, Kaifile.name_rules(primary)),
									)?
									selected = Plugin.select_required_named_block(
										text,
										block_name,
										name,
										choice,
										os,
										explicit_backend_block,
									)?
									parsed = Plugin.find_parsed_block(
										blocks,
										selected,
									) ? |_|
										{
											location: At(selected.location),
											message: Str.join_with(
												[
													"selected ${block_name}",
													"'${name}' was not parsed",
												],
												" ",
											),
										}
									related_name = Fields.get_string(
										parsed.fields,
										reference.field.name,
									) ? |_|
										{
											location: None,
											message: Str.join_with(
												[
													"validated ${block_name} '${name}' is",
													"missing '${reference.field.name}'",
												],
												" ",
											),
										}
									related = Kaifile.from_reference_target(reference.target)
									referenced_block = Plugin.select_required_named_block(
										text,
										Kaifile.block_name(related),
										related_name,
										choice,
										os,
										explicit_backend_block,
									)?
									Ok(
										SelectedWithReference({
											reference_field: reference.field.name,
											referenced_block,
											selected_block: selected,
										}),
									)
								}
								([name], []) =>
									Plugin.select_named_block(
										text,
										primary,
										name,
										choice,
										os,
										explicit_backend_block,
									)
								_ => Err({
									location: None,
									message: "${command_name} requires exactly one block name",
								})
							}
						} else {
							Plugin.select_with_backend_fallback(
								text,
								[block_name],
								choice,
								os,
								explicit_backend_block,
							)
						}
					OptionalBlock =>
						Plugin.select_with_backend_fallback(
							text,
							[block_name],
							choice,
							os,
							explicit_backend_block,
						)
					ByOptionalArgument({ argument: _, when_provided }) => {
						named = Kaifile.from_schema(when_provided)
						named_block = Kaifile.block_name(named)
						match args {
							[] =>
								match choice {
									DefaultBackend(_) =>
										Plugin.select_block_header(
											text,
											[block_name],
											choice,
											os,
										)
									ExplicitBackend(backend) =>
										match Plugin.select_block_header(
											text,
											[named_block, backend.name],
											DefaultBackend(backend),
											os,
										)? {
											Missing =>
												Plugin.select_block_header(
													text,
													[block_name],
													choice,
													os,
												)
											Selected(selected) => Ok(Selected(selected))
											_ => Err({
												location: None,
												message: "invalid ${named_block} selection",
											})
										}
									}
							[name] =>
								Plugin.select_named_block(
									text,
									named,
									name,
									choice,
									os,
									explicit_backend_block,
								)
							_ => Err({
								location: None,
								message: "${command_name} accepts at most one block name",
							})
						}
					}
				}
			}
		}

	same_block_key : Block, Block -> Bool
	same_block_key = |left, right|
		Kaifile.block_name(left) == Kaifile.block_name(right) and
			Kaifile.is_named(left) == Kaifile.is_named(right)

	compatible_blocks : Block, Block -> Bool
	compatible_blocks = |left, right|
		Plugin.same_block_key(left, right) and
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
		Command,
		BackendChoice,
		List(Str) -> {
			args : List(Str),
			backend_choice : BackendChoice,
		}
	normalize_command_backend = |command, backend_choice, args|
		match command {
			CommandWithBlock({ block, syntax: _, explicit_backend_block: _ }) =>
				match block.selection {
					RequiredBlock if Kaifile.is_named(block) =>
						match (backend_choice, args) {
							(ExplicitBackend(backend), []) => {
								args: [backend.name],
								backend_choice: DefaultBackend(backend),
							}
							_ => { args, backend_choice }
						}
					_ => { args, backend_choice }
				}
			CommandOnly(_) => { args, backend_choice }
		}

	validate_command_arguments : CommandSyntax, List(Str) -> Try({}, Str)
	validate_command_arguments = |declared_command, args|
		match declared_command.arguments {
			[] => if args.is_empty() Ok({}) else Err("command does not accept arguments")
			[OptionalArgument(name)] =>
				match args {
					[] | [_] => Ok({})
					_ => Err(
						"${declared_command.name} accepts at most one ${name} argument",
					)
				}
			[RequiredArgument(name)] =>
				match args {
					[_] => Ok({})
					_ => Err(
						"${declared_command.name} requires exactly one ${name} argument",
					)
				}
			_ => Err("command declares unsupported arguments")
		}

	select_named_block :
		Str,
		Block,
		Str,
		BackendChoice,
		HostOs,
		ExplicitBackendBlock -> Try(
			BlockSelection,
			SelectorDiagnostic,
		)
	select_named_block = |text, schema, name, choice, os, backend_block| {
		Plugin.selector_validation(
			Plugin.validate_text(name, Kaifile.name_rules(schema)),
		)?
		block = Plugin.select_required_named_block(
			text,
			Kaifile.block_name(schema),
			name,
			choice,
			os,
			backend_block,
		)?
		Ok(Selected(block))
	}

	select_required_named_block :
		Str,
		Str,
		Str,
		BackendChoice,
		HostOs,
		ExplicitBackendBlock -> Try(
			LocatedBlock,
			SelectorDiagnostic,
		)
	select_required_named_block =
		|text, block, name, choice, os, explicit_backend_block|
			match Plugin.select_with_backend_fallback(
				text,
				[block, name],
				choice,
				os,
				explicit_backend_block,
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
		ExplicitBackendBlock -> Try(
			BlockSelection,
			SelectorDiagnostic,
		)
	select_with_backend_fallback =
		|text, header, choice, os, explicit_backend_block| {
			selection = Plugin.select_block_header(
				text,
				header,
				choice,
				os,
			)?
			match (selection, choice, explicit_backend_block) {
				(Missing, ExplicitBackend(backend), TryBackendThenShared) =>
					Plugin.select_block_header(
						text,
						header,
						DefaultBackend(backend),
						os,
					)
				_ => Ok(selection)
			}
		}

	# Select a generic, possibly named block while retaining the standard host
	# fallback and explicit-backend behavior.
	select_block_header :
		Str,
		List(Str),
		BackendChoice,
		HostOs -> Try(
			BlockSelection,
			SelectorDiagnostic,
		)
	select_block_header = |kaifile_text, header, backend_choice, os| {
		block_header = match backend_choice {
			DefaultBackend(_) => header
			ExplicitBackend(backend) => header.append(backend.name)
		}
		blocks = Blocks.scan(kaifile_text) ? |diagnostic| {
			location: At(Plugin.source_location(diagnostic.location)),
			message: "invalid Kaifile",
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
					Plugin.top_level_duplicate(selection_error, "duplicate host block")
				match host_selection {
					Missing => Plugin.select_top_level(blocks, block_header)
					Selected(host) =>
						match Plugin.select_nested(host, block_header)? {
							Missing => Plugin.select_top_level(blocks, block_header)
							Selected(block) => Ok(Selected(block))
							SelectedWithReference(selected) => Ok(SelectedWithReference(selected))
						}
					}
			}
		}
	}

	select_top_level :
		List(Blocks.Block), List(Str) -> Try(BlockSelection, SelectorDiagnostic)
	select_top_level = |blocks, header| {
		selection = Blocks.select_exact(blocks, header) ? |selection_error|
			Plugin.top_level_duplicate(
				selection_error,
				"duplicate command block",
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
		Blocks.Block, List(Str) -> Try(BlockSelection, SelectorDiagnostic)
	select_nested = |host, header| {
		blocks = Blocks.scan(host.body) ? |diagnostic| {
			location: At(Plugin.nested_location(host, diagnostic.location)),
			message: "invalid host block",
		}
		selection = Blocks.select_exact(blocks, header) ? |selection_error| {
			location = match selection_error {
				DuplicateHeader({ first: _, header: _, second }) =>
					At(Plugin.nested_location(host, second))
				}
			{ location, message: "duplicate command block" }
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

	BlockScope : [HostBlockScope(Blocks.Block), TopLevelBlockScope]

	parse_kaifile_blocks : Str,
	List(Block),
	Str -> Try(
		List(ParsedBlock),
		SelectorDiagnostic,
	)
	parse_kaifile_blocks = |kaifile_text, block_schemas, backend| {
		blocks = Blocks.scan(kaifile_text) ? |diagnostic| {
			location: At(Plugin.source_location(diagnostic.location)),
			message: "invalid Kaifile",
		}
		Plugin.collect_kaifile_blocks(
			blocks,
			block_schemas,
			backend,
			TopLevelBlockScope,
			Bool.True,
			[],
			[],
		)
	}

	collect_kaifile_blocks :
		List(Blocks.Block),
		List(Block),
		Str,
		BlockScope,
		Bool,
		List(List(Str)),
		List(ParsedBlock) -> Try(
			List(ParsedBlock),
			SelectorDiagnostic,
		)
	collect_kaifile_blocks = |blocks, schemas, backend, scope, hosts, seen, parsed|
		match blocks {
			[] => Ok(parsed)
			[first, .. as rest] =>
				match Plugin.find_block_schema(schemas, first.header, backend) {
					Some(block_schema) =>
						if seen.contains(first.header) {
							Err({
								location: At(Plugin.block_location(first, scope).location),
								message: "duplicate Kaifile block",
							})
						} else {
							located = Plugin.block_location(first, scope)
							parsed_block = Plugin.parse_block(
								block_schema,
								first.header,
								located,
							)?
							Plugin.collect_kaifile_blocks(
								rest,
								schemas,
								backend,
								scope,
								hosts,
								seen.append(first.header),
								parsed.append(parsed_block),
							)
						}
					None if hosts and Plugin.is_host_section(first.header) =>
						if seen.contains(first.header) {
							Err({
								location: At(Plugin.source_location(first.location)),
								message: "duplicate host block",
							})
						} else {
							nested = Blocks.scan(first.body) ? |diagnostic| {
								location: At(Plugin.nested_location(first, diagnostic.location)),
								message: "invalid host block",
							}
							nested_parsed = Plugin.collect_kaifile_blocks(
								nested,
								schemas,
								backend,
								HostBlockScope(first),
								Bool.False,
								[],
								[],
							)?
							Plugin.collect_kaifile_blocks(
								rest,
								schemas,
								backend,
								scope,
								hosts,
								seen.append(first.header),
								parsed.concat(nested_parsed),
							)
						}
					None =>
						Plugin.collect_kaifile_blocks(
							rest,
							schemas,
							backend,
							scope,
							hosts,
							seen,
							parsed,
						)
					}
			}

	find_block_schema :
		List(Block), List(Str), Str -> [None, Some(Block)]
	find_block_schema = |blocks, header, backend|
		match header {
			[kind] => Plugin.find_block_of_kind(blocks, kind, Bool.False)
			[kind, name] =>
				if name == backend {
					match Plugin.find_block_of_kind(blocks, kind, Bool.False) {
						Some(block) => Some(block)
						None => Plugin.find_block_of_kind(blocks, kind, Bool.True)
					}
				} else {
					Plugin.find_block_of_kind(blocks, kind, Bool.True)
				}
			[kind, _, qualifier] if qualifier == backend =>
				Plugin.find_block_of_kind(blocks, kind, Bool.True)
			_ => None
		}

	find_block_of_kind :
		List(Block), Str, Bool -> [None, Some(Block)]
	find_block_of_kind = |blocks, kind, named|
		match blocks {
			[] => None
			[first, .. as rest] =>
				if Kaifile.block_name(first) == kind and Kaifile.is_named(first) == named {
					Some(first)
				} else {
					Plugin.find_block_of_kind(rest, kind, named)
				}
			}

	is_host_section : List(Str) -> Bool
	is_host_section = |header|
		header == ["on", "linux"] or header == ["on", "macos"]

	block_location : Blocks.Block, BlockScope -> LocatedBlock
	block_location = |block, scope|
		match scope {
			TopLevelBlockScope => {
				body: block.body,
				location: Plugin.source_location(block.location),
			}
			HostBlockScope(host) => {
				body: block.body,
				location: Plugin.nested_location(host, block.location),
			}
		}

	parse_block :
		Block,
		List(Str),
		LocatedBlock -> Try(
			ParsedBlock,
			SelectorDiagnostic,
		)
	parse_block = |schema, header, block| {
		fields = Fields.parse(Kaifile.body(schema), block.body) ? |diagnostic| {
			location: At(Plugin.translate_location(block, diagnostic.byte_offset)),
			message: Fields.describe(diagnostic),
		}
		Ok({
			fields,
			header,
			kind: Kaifile.block_name(schema),
			location: block.location,
		})
	}

	find_parsed_block :
		List(ParsedBlock), LocatedBlock -> Try(ParsedBlock, [NotFound])
	find_parsed_block = |blocks, selected|
		match blocks {
			[] => Err(NotFound)
			[first, .. as rest] =>
				if first.location.byte_offset == selected.location.byte_offset {
					Ok(first)
				} else {
					Plugin.find_parsed_block(rest, selected)
				}
			}

	ReferencedFields : [
		NoReferencedFields,
		SelectedReferencedFields(
			{
				field : Str,
				fields : Fields.ParsedFields,
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

	PrerequisiteArtifacts : [NotResolved, Resolved(List(Artifact))]

	CommandPlanningInput := {
		backend_target : [BackendTarget(Str), NoBackendTarget],
		command_arguments : List(Str),
		command_fields : Fields.ParsedFields,
		host : Host,
		kaifile_blocks : List(ParsedBlock),
		prerequisite_artifacts : PrerequisiteArtifacts,
		referenced_fields : ReferencedFields,
		workspace_root : Str,
	}

	StringListValidation := {
		field : KaifileField,
		rules : List(StringListRule),
	}

	TargetValidation : [
		NoTargetValidation,
		SupportedTargets(
			{ message : Str, supported : List(SupportedBackendTarget) },
		),
	]

	Validator : [
		NoValidation,
		Validate(
			{ string_lists : List(StringListValidation), target : TargetValidation },
		),
	]

	PrerequisiteCommand := {
		arguments : List(Str),
		description : Str,
	}

	same_prerequisite_commands :
		List(PrerequisiteCommand), List(PrerequisiteCommand) -> Bool
	same_prerequisite_commands = |left, right|
		match (left, right) {
			([], []) => Bool.True
			([left_first, .. as left_rest], [right_first, .. as right_rest]) =>
				left_first.arguments == right_first.arguments and
					left_first.description == right_first.description and
						Plugin.same_prerequisite_commands(left_rest, right_rest)
			_ => Bool.False
		}

	BackendCommandPlan := {
		artifacts : List(Artifact),
		prerequisite_commands : List(PrerequisiteCommand),
		requested_packages : List(Str),
		steps : List(ExecutionStep),
	}

	BackendPlanningDiagnostic := {
		byte_offset : [At(U64), None],
		message : Str,
	}

	Implementation := {
		backend : Str,
		command : Str,
		plan :
			CommandPlanningInput ->
				Try(
					BackendCommandPlan,
					BackendPlanningDiagnostic,
				),
		validator : Validator,
	}

	blocks_of_kind : CommandPlanningInput, List(Str) -> List(ParsedBlock)
	blocks_of_kind = |input, kinds|
		input.kaifile_blocks.keep_if(|block| kinds.contains(block.kind))

	referenced_fields :
		CommandPlanningInput,
		Str -> Try(
			Fields.ParsedFields,
			BackendPlanningDiagnostic,
		)
	referenced_fields = |input, field|
		match input.referenced_fields {
			NoReferencedFields => Err({
				byte_offset: None,
				message: "validated command block has no reference field '${field}'",
			})
			SelectedReferencedFields({ field: selected_field, fields }) =>
				if selected_field == field {
					Ok(fields)
				} else {
					Err({
						byte_offset: None,
						message: Str.join_with(
							[
								"validated command block reference field",
								"'${selected_field}' does not match '${field}'",
							],
							" ",
						),
					})
				}
			}

	validate_implementation_input : CommandPlanningInput,
	Validator -> Try(
		CommandPlanningInput,
		BackendPlanningDiagnostic,
	)
	validate_implementation_input = |input, validator|
		match validator {
			NoValidation => Ok(input)
			Validate({ string_lists, target }) => {
				backend_target = match target {
					NoTargetValidation => Ok(NoBackendTarget)
					SupportedTargets({ message, supported }) =>
						match Plugin.target_value(supported, input.host.os, input.host.arch) {
							Ok(value) => Ok(BackendTarget(value))
							Err(_) => Err({ byte_offset: None, message })
						}
					}?
				failures = Plugin.validate_string_list_fields(
					input.command_fields,
					string_lists,
				)?
				Plugin.implementation_validation(failures)?
				Ok(
					Plugin.CommandPlanningInput.{
						backend_target,
						command_arguments: input.command_arguments,
						command_fields: input.command_fields,
						host: input.host,
						kaifile_blocks: input.kaifile_blocks,
						prerequisite_artifacts: input.prerequisite_artifacts,
						referenced_fields: input.referenced_fields,
						workspace_root: input.workspace_root,
					},
				)
			}
		}

	validate_string_list_fields :
		Fields.ParsedFields,
		List(StringListValidation) -> Try(
			List(Str),
			BackendPlanningDiagnostic,
		)
	validate_string_list_fields = |fields, validations|
		match validations {
			[] => Ok([])
			[first, .. as rest] => {
				values = Plugin.validated_strings(fields, first.field)?
				remaining = Plugin.validate_string_list_fields(fields, rest)?
				Ok(Plugin.validate_string_list(values, first.rules).concat(remaining))
			}
		}

	validated_strings : Fields.ParsedFields,
	KaifileField -> Try(
		List(Str),
		BackendPlanningDiagnostic,
	)
	validated_strings = |fields, declared_field| {
		field = Kaifile.parser_field(declared_field)
		match Fields.get_strings(fields, field.name) {
			Ok(values) => Ok(values)
			Err(MissingField(_)) if field.presence == Optional => Ok([])
			Err(_) => Err({
				byte_offset: None,
				message: Str.join_with(
					[
						"validated fields do not match declared block schema",
						"'${field.name}'",
					],
					" ",
				),
			})
		}
	}

	validated_backend_target :
		CommandPlanningInput -> Try(Str, BackendPlanningDiagnostic)
	validated_backend_target = |input|
		match input.backend_target {
			BackendTarget(value) => Ok(value)
			NoBackendTarget => Err({
				byte_offset: None,
				message: "implementation requires a validated backend target",
			})
		}

	target_value : List(SupportedBackendTarget),
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
		implementations : List(Implementation),
		name : Str,
		schema : Schema,
	}

	RegistryDiagnostic := {
		message : Str,
		plugin : Str,
	}

	validate_registry : List(Definition) -> Try({}, RegistryDiagnostic)
	validate_registry = |registry| {
		Plugin.validate_definitions(registry)?
		Plugin.validate_block_compatibility(registry)
	}

	validate_definitions : List(Definition) -> Try({}, RegistryDiagnostic)
	validate_definitions = |registry|
		match registry {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.validate_definition(first)?
				Plugin.validate_definitions(rest)
			}
		}

	validate_definition : Definition -> Try({}, RegistryDiagnostic)
	validate_definition = |definition|
		if definition.schema.commands.is_empty() {
			Plugin.registry_failure(definition.name, "must define at least one command")
		} else if definition.backends.is_empty() {
			Plugin.registry_failure(definition.name, "must define at least one backend")
		} else if definition.implementations.is_empty() {
			Plugin.registry_failure(
				definition.name,
				"must define at least one implementation",
			)
		} else {
			Plugin.validate_blocks(
				definition.schema.blocks,
				definition.schema.blocks,
				definition.name,
			)?
			Plugin.validate_command_syntaxes(
				definition.schema.commands,
				definition.name,
			)?
			Plugin.validate_commands(
				definition.schema.commands,
				definition.name,
			)?
			Plugin.validate_command_block_relationships(
				definition.schema.commands,
				definition.schema.blocks,
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
						definition.schema.commands,
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

	validate_command_syntaxes : List(Command), Str -> Try({}, RegistryDiagnostic)
	validate_command_syntaxes = |commands, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] => {
				declared_command = Plugin.syntax_from_command(first)
				match declared_command.arguments {
					[] => Plugin.validate_command_syntaxes(rest, plugin)
					[OptionalArgument(name)] | [RequiredArgument(name)] =>
						if name.is_empty() {
							Plugin.registry_failure(
								plugin,
								Str.join_with(
									[
										"command '${declared_command.name}' argument",
										"name must not be empty",
									],
									" ",
								),
							)
						} else {
							Plugin.validate_command_syntaxes(rest, plugin)
						}
					_ =>
						Plugin.registry_failure(
							plugin,
							Str.join_with(
								[
									"command '${declared_command.name}' must declare",
									"at most one argument",
								],
								" ",
							),
						)
					}
			}
		}

	validate_commands :
		List(Command), Str -> Try({}, RegistryDiagnostic)
	validate_commands = |commands, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] => {
				command_validation = match first {
					CommandOnly(_) => Ok({})
					CommandWithBlock(
						{
							block,
							syntax: declared_command,
							explicit_backend_block: _,
						},
					) =>
						match block.selection {
							RequiredBlock => {
								Plugin.validate_schema_kind(
									block,
									Kaifile.is_named(block),
									declared_command.name,
									plugin,
								)?
								if Kaifile.is_named(block) {
									Plugin.validate_required_schema_argument(
										declared_command,
										block,
										plugin,
									)
								} else {
									Ok({})
								}
							}
							OptionalBlock =>
								Plugin.validate_schema_kind(
									block,
									Bool.False,
									declared_command.name,
									plugin,
								)
							ByOptionalArgument({ argument, when_provided }) => {
								named = Kaifile.from_schema(when_provided)
								Plugin.validate_schema_kind(
									block,
									Bool.False,
									declared_command.name,
									plugin,
								)?
								Plugin.validate_schema_kind(
									named,
									Bool.True,
									declared_command.name,
									plugin,
								)?
								Plugin.validate_optional_schema_argument(
									declared_command,
									argument,
									named,
									plugin,
								)
							}
						}
					}
				command_validation?
				Plugin.validate_command_references(first, plugin)?
				Plugin.validate_commands(rest, plugin)
			}
		}

	validate_schema_kind :
		Block, Bool, Str, Str -> Try({}, RegistryDiagnostic)
	validate_schema_kind = |schema, expected_named, command_name, plugin| {
		Kaifile.validate_header(schema) ? |message| { message, plugin }
		if Kaifile.is_named(schema) == expected_named {
			Ok({})
		} else {
			expected = if expected_named "named" else "unnamed"
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

	validate_command_references :
		Command, Str -> Try({}, RegistryDiagnostic)
	validate_command_references = |command, plugin|
		match command {
			CommandOnly(_) => Ok({})
			CommandWithBlock(
				{
					block,
					syntax: declared_command,
					explicit_backend_block: _,
				},
			) =>
				match block.selection {
					RequiredBlock if Kaifile.is_named(block) =>
						match Kaifile.references(block) {
							[] => Ok({})
							[_] =>
								Plugin.validate_reference_relationship(
									block,
									declared_command.name,
									plugin,
								)
							_ => Plugin.reference_count_failure(declared_command.name, plugin)
						}
					RequiredBlock | OptionalBlock =>
						Plugin.validate_no_reference_fields(
							block,
							declared_command.name,
							plugin,
						)
					ByOptionalArgument({ argument: _, when_provided }) => {
						Plugin.validate_no_reference_fields(
							block,
							declared_command.name,
							plugin,
						)?
						Plugin.validate_no_reference_fields(
							Kaifile.from_schema(when_provided),
							declared_command.name,
							plugin,
						)
					}
				}
			}

	validate_no_reference_fields :
		Block, Str, Str -> Try({}, RegistryDiagnostic)
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
		Block, Str, Str -> Try({}, RegistryDiagnostic)
	validate_reference_relationship = |primary, command_name, plugin|
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
		CommandSyntax, Block, Str -> Try({}, RegistryDiagnostic)
	validate_required_schema_argument = |declared_command, schema, plugin|
		match (declared_command.arguments, Kaifile.header_argument(schema)) {
			([RequiredArgument(argument)], HeaderArgument(slot)) if argument == slot =>
				Ok({})
			_ =>
				Plugin.registry_failure(
					plugin,
					Str.join_with(
						[
							"command '${declared_command.name}' must declare one required",
							"argument matching its Kaifile header slot",
						],
						" ",
					),
				)
			}

	validate_optional_schema_argument :
		CommandSyntax, Str, Block, Str -> Try({}, RegistryDiagnostic)
	validate_optional_schema_argument =
		|declared_command, selected_argument, schema, plugin| {
			failure = |_|
				Plugin.registry_failure(
					plugin,
					Str.join_with(
						[
							"command '${declared_command.name}' must use one optional",
							"argument matching its Kaifile header slot",
						],
						" ",
					),
				)
			match (declared_command.arguments, Kaifile.header_argument(schema)) {
				([OptionalArgument(argument)], HeaderArgument(slot)) =>
					if argument == selected_argument and argument == slot {
						Ok({})
					} else {
						failure({})
					}
				_ => failure({})
			}
		}

	validate_blocks :
		List(Block), List(Block), Str -> Try({}, RegistryDiagnostic)
	validate_blocks = |blocks, all_blocks, plugin|
		match blocks {
			[] => Ok({})
			[first, .. as rest] => {
				Kaifile.validate_header(first) ? |message| { message, plugin }
				Plugin.validate_unique_block_key(first, rest, plugin)?
				Plugin.validate_block_reference_targets(first, all_blocks, plugin)?
				Plugin.validate_blocks(rest, all_blocks, plugin)
			}
		}

	validate_unique_block_key :
		Block, List(Block), Str -> Try({}, RegistryDiagnostic)
	validate_unique_block_key = |block, remaining, plugin|
		if List.any(remaining, |other| Plugin.same_block_key(block, other)) {
			kind = if Kaifile.is_named(block) "named" else "unnamed"
			Plugin.registry_failure(
				plugin,
				"duplicate ${kind} Kaifile block '${Kaifile.block_name(block)}'",
			)
		} else {
			Ok({})
		}

	validate_command_block_relationships :
		List(Command), List(Block), Str -> Try({}, RegistryDiagnostic)
	validate_command_block_relationships = |commands, blocks, plugin|
		match commands {
			[] => Ok({})
			[first, .. as rest] => {
				match first {
					CommandOnly(_) => Ok({})
					CommandWithBlock(
						{ block, syntax: declared_command, explicit_backend_block: _ },
					) => {
						Plugin.validate_block_relationship(
							block,
							blocks,
							"command '${declared_command.name}' primary block",
							plugin,
						)?
						Plugin.validate_block_reference_targets(block, blocks, plugin)?
						match block.selection {
							ByOptionalArgument({ argument: _, when_provided }) => {
								alternative = Kaifile.from_schema(when_provided)
								Plugin.validate_block_relationship(
									alternative,
									blocks,
									"command '${declared_command.name}' optional alternative",
									plugin,
								)?
								Plugin.validate_block_reference_targets(
									alternative,
									blocks,
									plugin,
								)
							}
							RequiredBlock | OptionalBlock => Ok({})
						}
					}
				}?
				Plugin.validate_command_block_relationships(rest, blocks, plugin)
			}
		}

	validate_block_reference_targets :
		Block, List(Block), Str -> Try({}, RegistryDiagnostic)
	validate_block_reference_targets = |block, blocks, plugin|
		Plugin.validate_reference_targets(Kaifile.references(block), blocks, plugin)

	validate_reference_targets = |references, blocks, plugin|
		match references {
			[] => Ok({})
			[first, .. as rest] => {
				target = Kaifile.from_reference_target(first.target)
				Plugin.validate_block_relationship(
					target,
					blocks,
					"reference field '${first.field.name}' target",
					plugin,
				)?
				Plugin.validate_reference_targets(rest, blocks, plugin)
			}
		}

	validate_block_relationship :
		Block, List(Block), Str, Str -> Try({}, RegistryDiagnostic)
	validate_block_relationship = |block, blocks, relationship, plugin|
		if Plugin.compatible_block_count(block, blocks) == 1 {
			Ok({})
		} else {
			Plugin.registry_failure(
				plugin,
				Str.join_with(
					[
						relationship,
						"must match exactly one compatible schema.blocks entry",
					],
					" ",
				),
			)
		}

	compatible_block_count : Block, List(Block) -> U64
	compatible_block_count = |block, blocks|
		match blocks {
			[] => 0
			[first, .. as rest] =>
				(if Plugin.compatible_blocks(block, first) 1 else 0) +
					Plugin.compatible_block_count(block, rest)
			}

	validate_block_compatibility : List(Definition) -> Try({}, RegistryDiagnostic)
	validate_block_compatibility = |registry|
		match registry {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.validate_plugin_blocks(
					first.schema.blocks,
					first.name,
					rest,
				)?
				Plugin.validate_block_compatibility(rest)
			}
		}

	validate_plugin_blocks :
		List(Block), Str, List(Definition) -> Try({}, RegistryDiagnostic)
	validate_plugin_blocks = |blocks, plugin, definitions|
		match blocks {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.validate_block_across_plugins(first, plugin, definitions)?
				Plugin.validate_plugin_blocks(rest, plugin, definitions)
			}
		}

	validate_block_across_plugins :
		Block, Str, List(Definition) -> Try({}, RegistryDiagnostic)
	validate_block_across_plugins = |block, plugin, definitions|
		match definitions {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.validate_block_against(block, plugin, first.schema.blocks)?
				Plugin.validate_block_across_plugins(block, plugin, rest)
			}
		}

	validate_block_against :
		Block, Str, List(Block) -> Try({}, RegistryDiagnostic)
	validate_block_against = |block, plugin, others|
		match others {
			[] => Ok({})
			[first, .. as rest] =>
				if Plugin.same_block_key(block, first) and
					!Plugin.compatible_blocks(block, first) {
					kind = if Kaifile.is_named(block) "named" else "unnamed"
					Plugin.registry_failure(
						plugin,
						Str.join_with(
							[
								"${kind} Kaifile block",
								"'${Kaifile.block_name(block)}' has conflicting",
								"body shapes across plugins",
							],
							" ",
						),
					)
				} else {
					Plugin.validate_block_against(block, plugin, rest)
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
				match Plugin.find_command(definition.schema.commands, first.command) {
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
			[first, .. as rest] => {
				declared_command = Plugin.syntax_from_command(first)
				match Plugin.find_implementation(
					implementations,
					declared_command.name,
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
									"command '${declared_command.name}' has no",
									"implementation for default backend",
									"'${backend}'",
								],
								" ",
							),
						)
					}
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

	ExecutionPlan := {
		artifacts : List(Artifact),
		backend : Backend,
		command : Str,
		plugin : Str,
		requested_packages : List(Str),
		steps : List(ExecutionStep),
	}.{
		encoder_for : _
		parser_for : _
	}

	# Plan the first definition that owns the CLI command.
	plan_registry : List(Definition),
	Str,
	List(Str),
	HostOs,
	HostArch,
	Str -> Try(
		ExecutionPlan,
		Error,
	)
	plan_registry = |registry, kaifile_text, args, os, arch, workspace_root| {
		Plugin.validate_workspace_root(workspace_root) ? |message|
			InvalidWorkspaceRoot(message)
		Plugin.plan_registry_nested(
			registry,
			kaifile_text,
			args,
			os,
			arch,
			workspace_root,
			[],
			0,
		)
	}

	plan_registry_nested :
		List(Definition),
		Str,
		List(Str),
		HostOs,
		HostArch,
		Str,
		List(List(Str)),
		U64 -> Try(
			ExecutionPlan,
			Error,
		)
	plan_registry_nested =
		|registry, kaifile_text, args, os, arch, workspace_root, ancestors, depth|
			match args {
				[] => Err(UnknownCommand)
				[command_name, .. as command_args] => {
					owner = match Plugin.find_owner(registry, command_name) {
						Ok(found) => found
						Err(UnknownCommand) => return Err(UnknownCommand)
					}
					plugin_definition = owner.definition
					selected_command = owner.command
					declared_command = Plugin.syntax_from_command(selected_command)
					plugin = plugin_definition.name
					selected_command_name = declared_command.name
					backend_selection = Plugin.select_backend(
						plugin_definition.backends,
						command_args,
					) ? |backend_name|
						PlanningFailed(
							Plugin.failure(
								plugin,
								selected_command_name,
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
					normalized_invocation = Plugin.normalize_command_backend(
						selected_command,
						backend_selection.choice,
						backend_selection.args,
					)
					fail = |location, message|
						PlanningFailed(
							Plugin.failure(
								plugin,
								selected_command_name,
								backend.name,
								location,
								message,
							),
						)

					if List.any(ancestors, |ancestor| ancestor == args) {
						Err(fail(None, "prerequisite command cycle detected"))
					} else if depth >= 64 {
						Err(fail(None, "prerequisite command nesting exceeds 64 levels"))
					} else {
						Plugin.validate_command_arguments(
							declared_command,
							normalized_invocation.args,
						) ? |message| fail(None, message)
						implementation = Plugin.find_implementation(
							plugin_definition.implementations,
							selected_command_name,
							backend.name,
						) ? |_|
							fail(
								None,
								"plugin has no implementation for selected backend",
							)
						kaifile_blocks = Plugin.parse_kaifile_blocks(
							kaifile_text,
							Plugin.accepted_blocks(registry),
							backend.name,
						) ? |diagnostic|
							fail(diagnostic.location, diagnostic.message)
						selection = Plugin.select_command_block(
							kaifile_text,
							kaifile_blocks,
							selected_command,
							normalized_invocation.backend_choice,
							normalized_invocation.args,
							os,
							arch,
						) ? |diagnostic|
							fail(diagnostic.location, diagnostic.message)
						parsed = match (selected_command, selection) {
							(CommandOnly(_), _) => Ok({
								command_fields: Fields.empty,
								referenced_fields: NoReferencedFields,
							})
							(
								CommandWithBlock(
									{ block: schema, syntax: _, explicit_backend_block: _ },
								),
								Missing,
							) =>
								match schema.selection {
									OptionalBlock => Ok({
										command_fields: Fields.empty,
										referenced_fields: NoReferencedFields,
									})
									RequiredBlock | ByOptionalArgument(_) =>
										Err(
											fail(
												None,
												Str.join_with(
													[
														"missing required block",
														"'${Kaifile.block_name(schema)}'",
													],
													" ",
												),
											),
										)
									}
							(
								CommandWithBlock({ block: _, syntax: _, explicit_backend_block: _ }),
								Selected(block),
							) => {
								parsed_block = Plugin.find_parsed_block(kaifile_blocks, block) ? |_|
									fail(At(block.location), "selected Kaifile block was not parsed")
								Ok({
									command_fields: parsed_block.fields,
									referenced_fields: NoReferencedFields,
								})
							}
							(
								CommandWithBlock({ block: _, syntax: _, explicit_backend_block: _ }),
								SelectedWithReference(
									{ reference_field, referenced_block, selected_block },
								),
							) => {
								parsed_block = Plugin.find_parsed_block(
									kaifile_blocks,
									selected_block,
								) ? |_|
									fail(
										At(selected_block.location),
										"selected Kaifile block was not parsed",
									)
								referenced = Plugin.find_parsed_block(
									kaifile_blocks,
									referenced_block,
								) ? |_|
									fail(
										At(referenced_block.location),
										"referenced Kaifile block was not parsed",
									)
								Ok({
									command_fields: parsed_block.fields,
									referenced_fields: SelectedReferencedFields({
										field: reference_field,
										fields: referenced.fields,
									}),
								})
							}
						}?
						input = Plugin.CommandPlanningInput.{
							backend_target: NoBackendTarget,
							command_arguments: normalized_invocation.args,
							command_fields: parsed.command_fields,
							host: { arch, os },
							kaifile_blocks,
							prerequisite_artifacts: NotResolved,
							referenced_fields: parsed.referenced_fields,
							workspace_root,
						}
						implementation_fail = |diagnostic|
							fail(
								Plugin.implementation_location(
									selection,
									diagnostic.byte_offset,
								),
								diagnostic.message,
							)
						validated_input = Plugin.validate_implementation_input(
							input,
							implementation.validator,
						) ? |diagnostic| implementation_fail(diagnostic)
						plan_implementation = implementation.plan
						initial_command_plan = plan_implementation(validated_input) ? |diagnostic|
							implementation_fail(diagnostic)
						prerequisites = Plugin.plan_prerequisite_commands(
							registry,
							kaifile_text,
							initial_command_plan.prerequisite_commands,
							os,
							arch,
							workspace_root,
							[args].concat(ancestors),
							depth + 1,
							plugin,
							selected_command_name,
							backend.name,
						)?
						command_plan = if initial_command_plan.prerequisite_commands.is_empty() {
							initial_command_plan
						} else {
							with_prerequisite_artifacts = plan_implementation(
								Plugin.CommandPlanningInput.{
									backend_target: validated_input.backend_target,
									command_arguments: validated_input.command_arguments,
									command_fields: validated_input.command_fields,
									host: validated_input.host,
									kaifile_blocks: validated_input.kaifile_blocks,
									prerequisite_artifacts: Resolved(prerequisites.artifacts),
									referenced_fields: validated_input.referenced_fields,
									workspace_root: validated_input.workspace_root,
								},
							) ? |diagnostic| implementation_fail(diagnostic)
							if Plugin.same_prerequisite_commands(
								with_prerequisite_artifacts.prerequisite_commands,
								initial_command_plan.prerequisite_commands,
							) {
								with_prerequisite_artifacts
							} else {
								return Err(
									fail(
										None,
										Str.join_with(
											[
												"prerequisite commands changed after",
												"artifacts resolved",
											],
											" ",
										),
									),
								)
							}
						}
						Ok(
							Plugin.ExecutionPlan.{
								artifacts: prerequisites.artifacts.concat(command_plan.artifacts),
								backend,
								command: implementation.command,
								plugin,
								requested_packages: prerequisites.requested_packages.concat(
									command_plan.requested_packages,
								),
								steps: prerequisites.steps.concat(command_plan.steps),
							},
						)
					}
				}
			}

	plan_prerequisite_commands :
		List(Definition),
		Str,
		List(PrerequisiteCommand),
		HostOs,
		HostArch,
		Str,
		List(List(Str)),
		U64,
		Str,
		Str,
		Str -> Try(
			{
				artifacts : List(Artifact),
				requested_packages : List(Str),
				steps : List(ExecutionStep),
			},
			Error,
		)
	plan_prerequisite_commands =
		|defs, text, commands, os, arch, root, parents, depth, plugin, cmd, back|
			match commands {
				[] => Ok({ artifacts: [], requested_packages: [], steps: [] })
				[first, .. as rest] => {
					child = Plugin.plan_registry_nested(
						defs,
						text,
						first.arguments,
						os,
						arch,
						root,
						parents,
						depth,
					) ? |error|
						match error {
							InvalidWorkspaceRoot(message) => InvalidWorkspaceRoot(message)
							UnknownCommand => PlanningFailed(
								Plugin.failure(
									plugin,
									cmd,
									back,
									None,
									Str.join_with(
										[
											"prerequisite command refers to unknown command",
											"'${first.arguments.first() ?? ""}'",
										],
										" ",
									),
								),
							)
							PlanningFailed(diagnostic) => PlanningFailed(diagnostic)
						}
					remaining = Plugin.plan_prerequisite_commands(
						defs,
						text,
						rest,
						os,
						arch,
						root,
						parents,
						depth,
						plugin,
						cmd,
						back,
					)?
					Ok({
						artifacts: child.artifacts.concat(remaining.artifacts),
						requested_packages: child.requested_packages.concat(
							remaining.requested_packages,
						),
						steps: [PrintLine(first.description)].concat(child.steps).concat(
							remaining.steps,
						),
					})
				}
			}

	accepted_blocks : List(Definition) -> List(Block)
	accepted_blocks = |registry|
		match registry {
			[] => []
			[first, .. as rest] =>
				first.schema.blocks.concat(Plugin.accepted_blocks(rest))
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
				match Plugin.find_command(first.schema.commands, command_name) {
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
				if Plugin.syntax_from_command(first).name == name {
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

	implementation_location : BlockSelection,
	[At(U64), None] -> [
		At(SourceLocation),
		None,
	]
	implementation_location = |selection, relative|
		match (selection, relative) {
			(Selected(block), At(byte_offset)) =>
				Plugin.relative_location(block, byte_offset)
			(
				SelectedWithReference(
					{ reference_field: _, referenced_block: _, selected_block },
				),
				At(byte_offset),
			) => Plugin.relative_location(selected_block, byte_offset)
			_ => None
		}

	relative_location : LocatedBlock, U64 -> [At(SourceLocation), None]
	relative_location = |block, byte_offset|
		if byte_offset <= block.body.to_utf8().len() {
			At(Plugin.translate_location(block, byte_offset))
		} else {
			None
		}

	translate_location : LocatedBlock, U64 -> SourceLocation
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

}
