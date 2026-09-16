# Nix backend capability definitions
import kai.Plugin

Nix := [].{
	backend : Plugin.Backend
	backend = Plugin.Backend.{
		determinate_system: Plugin.DeterminateSystem.{
			default_package_source: "nixpkgs",
			driver: Program("nix"),
			kind: Nix,
		},
		fallback: NoFallback,
		name: "nix",
		required_packages: [],
	}

	Target : { system : Str }

	NixScalar : [NixBool(Bool), NixI64(I64), NixString(Str)]
	NixValue : [NixList(List(NixScalar)), NixScalarValue(NixScalar)]
	Assignment := { path : Str, value : NixValue }

	supported_targets : List(Plugin.SupportedBackendTarget)
	supported_targets = [
		{ arch: X64, os: LINUX, value: "x86_64-linux" },
		{ arch: AARCH64, os: LINUX, value: "aarch64-linux" },
		{ arch: X64, os: MACOS, value: "x86_64-darwin" },
		{ arch: AARCH64, os: MACOS, value: "aarch64-darwin" },
	]

	target : Plugin.HostOs, Plugin.HostArch -> Try(Target, [UnsupportedPlatform])
	target = |os, arch| {
		system = Plugin.target_value(supported_targets, os, arch)?
		Ok({ system: system })
	}

	# Nix double-quoted strings accept printable ASCII except the characters
	# that begin escaping or interpolation.
	safe_string_rule : Str -> Plugin.TextRule
	safe_string_rule = |message|
		BytesInRanges({
			excluded: ['"', '$', '\\'],
			message,
			ranges: [{ max: '~', min: '!' }],
		})

	input_lines : List(Str) -> List(Str)
	input_lines = |overlays|
		overlays.map_with_index(
			|overlay, index|
				Str.join_with(
					[
						"  inputs.overlay${U64.to_str(index)}.url = \"",
						overlay,
						"\";",
					],
					"",
				),
		)

	source_input_lines = |sources|
		sources.map(
			|source|
				Str.join_with(
					[
						"  inputs.\"kai-source-${source.name}\".url = \"${source.url}\";\n",
						"  inputs.\"kai-source-${source.name}\".flake = false;",
					],
					"",
				),
		)

	source_attribute = |sources| {
		attributes = sources.map(
			|source| "\"${source.name}\" = inputs.\"kai-source-${source.name}\";",
		)
		Str.join_with(
			["kaiSources = { ", Str.join_with(attributes, " "), " };"],
			"",
		)
	}

	overlay_expression : List(Str), Str, U64 -> Str
	overlay_expression = |overlays, selected, index|
		match overlays {
			[] => "overlay0.overlays.default"
			[first, .. as rest] =>
				if first == selected {
					"overlay${U64.to_str(index)}.overlays.default"
				} else {
					Nix.overlay_expression(rest, selected, index + 1)
				}
			}

	overlay_outputs_args : List(Str) -> Str
	overlay_outputs_args = |overlays| {
		names = overlays.map_with_index(|_, index| "overlay${U64.to_str(index)}")
		Str.join_with(["nixpkgs"].concat(names), ", ")
	}

	parse_assignments = |selection|
		match selection {
			NoBackendBody => Ok([])
			BackendBody(backend_body) => {
				bytes = backend_body.body.to_utf8()
				Nix.parse_assignment_entries(bytes, 0, [], [])
			}
		}

	parse_assignment_entries = |bytes, raw_index, assignments, seen| {
		index = Nix.skip_assignment_trivia(bytes, raw_index)
		if index >= bytes.len() {
			Ok(assignments)
		} else {
			path_end = Nix.find_option_path_end(bytes, index)
			path = Nix.byte_slice(bytes, index, path_end)
			Nix.validate_option_path(path, index)?
			if seen.contains(path) {
				Nix.assignment_error(index, "duplicate NixOS option path '${path}'")?
			}
			colon = Nix.skip_assignment_trivia(bytes, path_end)
			if Nix.assignment_byte_at(bytes, colon) != ':' {
				Nix.assignment_error(
					colon,
					"expected ':' after NixOS option path '${path}'",
				)?
			}
			value_start = Nix.skip_assignment_trivia(bytes, colon + 1)
			parsed = Nix.parse_nix_value(bytes, value_start)?
			Nix.require_assignment_separator(bytes, parsed.rest)?
			Nix.parse_assignment_entries(
				bytes,
				parsed.rest,
				assignments.append({ path, value: parsed.value }),
				seen.append(path),
			)
		}
	}

	parse_nix_value = |bytes, index|
		if Nix.assignment_byte_at(bytes, index) == '[' {
			parsed = Nix.parse_nix_list(bytes, index + 1, [], Bool.True)?
			Ok({ rest: parsed.rest, value: NixList(parsed.values) })
		} else {
			parsed = Nix.parse_nix_scalar(bytes, index)?
			Ok({ rest: parsed.rest, value: NixScalarValue(parsed.value) })
		}

	parse_nix_list = |bytes, raw_index, values, allow_end| {
		index = Nix.skip_assignment_trivia(bytes, raw_index)
		byte = Nix.assignment_byte_at(bytes, index)
		if index >= bytes.len() {
			Nix.assignment_error(index, "unterminated NixOS option list")
		} else if byte == ']' and allow_end {
			Ok({ rest: index + 1, values })
		} else if byte == ']' {
			Nix.assignment_error(
				index,
				"expected a scalar after ',' in NixOS option list",
			)
		} else {
			parsed = Nix.parse_nix_scalar(bytes, index)?
			next = Nix.skip_assignment_trivia(bytes, parsed.rest)
			match Nix.assignment_byte_at(bytes, next) {
				',' => Nix.parse_nix_list(
					bytes,
					next + 1,
					values.append(parsed.value),
					Bool.False,
				)
				']' => Ok({
					rest: next + 1,
					values: values.append(parsed.value),
				})
				_ => Nix.assignment_error(
					next,
					"expected ',' or ']' in NixOS option list",
				)
			}
		}
	}

	parse_nix_scalar = |bytes, index| {
		byte = Nix.assignment_byte_at(bytes, index)
		if byte == '"' {
			parsed = Nix.parse_json_string(bytes, index)?
			Ok({ rest: parsed.rest, value: NixString(parsed.value) })
		} else if byte == '[' {
			Nix.assignment_error(index, "nested NixOS option lists are not supported")
		} else {
			end = Nix.find_scalar_end(bytes, index)
			raw = Nix.byte_slice(bytes, index, end)
			if raw == "true" {
				Ok({ rest: end, value: NixBool(Bool.True) })
			} else if raw == "false" {
				Ok({ rest: end, value: NixBool(Bool.False) })
			} else {
				match I64.from_str(raw) {
					Ok(value) => Ok({ rest: end, value: NixI64(value) })
					Err(_) => Nix.assignment_error(
						index,
						"expected a boolean, signed decimal I64, JSON string, or list",
					)
				}
			}
		}
	}

	parse_json_string = |bytes, start| {
		end = Nix.find_json_string_end(bytes, start + 1, Bool.False)?
		raw = Nix.byte_slice(bytes, start, end + 1)
		match Json.parse(raw) {
			Ok(value) => Ok({ rest: end + 1, value })
			Err(_) => Nix.assignment_error(start, "invalid JSON string")
		}
	}

	find_json_string_end = |bytes, index, escaped|
		if index >= bytes.len() {
			Nix.assignment_error(index, "unterminated JSON string")
		} else {
			byte = Nix.assignment_byte_at(bytes, index)
			if escaped {
				Nix.find_json_string_end(bytes, index + 1, Bool.False)
			} else if byte == '\\' {
				Nix.find_json_string_end(bytes, index + 1, Bool.True)
			} else if byte == '"' {
				Ok(index)
			} else {
				Nix.find_json_string_end(bytes, index + 1, Bool.False)
			}
		}

	find_option_path_end = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Nix.assignment_byte_at(bytes, index)
			if Nix.assignment_whitespace(byte) or byte == ':' or byte == '#' {
				index
			} else {
				Nix.find_option_path_end(bytes, index + 1)
			}
		}

	validate_option_path = |path, index| {
		segments = path.split_on(".")
		if path.is_empty() or List.any(segments, |segment| segment.is_empty()) {
			Nix.assignment_error(
				index,
				"NixOS option path must contain nonempty dotted segments",
			)
		} else if !List.all(segments, Nix.valid_option_path_segment) {
			Nix.assignment_error(
				index,
				Str.join_with(
					[
						"NixOS option path '${path}' may contain only ASCII ",
						"letters, digits, '_', and '-' in each segment",
					],
					"",
				),
			)
		} else {
			Ok({})
		}
	}

	valid_option_path_segment = |segment|
		List.all(
			segment.to_utf8(),
			|byte|
				(byte >= 'A' and byte <= 'Z') or
					(byte >= 'a' and byte <= 'z') or
						(byte >= '0' and byte <= '9') or
							byte == '_' or
								byte == '-',
		)

	find_scalar_end = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Nix.assignment_byte_at(bytes, index)
			if Nix.assignment_whitespace(byte) or
				byte == '#' or
					byte == ',' or
						byte == ']' {
				index
			} else {
				Nix.find_scalar_end(bytes, index + 1)
			}
		}

	require_assignment_separator = |bytes, index|
		if index >= bytes.len() or
			Nix.assignment_whitespace(Nix.assignment_byte_at(bytes, index)) or
				Nix.assignment_byte_at(bytes, index) == '#' {
			Ok({})
		} else {
			Nix.assignment_error(
				index,
				"expected whitespace between NixOS option assignments",
			)
		}

	skip_assignment_trivia = |bytes, index|
		if index >= bytes.len() {
			index
		} else {
			byte = Nix.assignment_byte_at(bytes, index)
			if Nix.assignment_whitespace(byte) {
				Nix.skip_assignment_trivia(bytes, index + 1)
			} else if byte == '#' {
				Nix.skip_assignment_trivia(bytes, Nix.skip_assignment_comment(bytes, index))
			} else {
				index
			}
		}

	skip_assignment_comment = |bytes, index|
		if index >= bytes.len() or Nix.assignment_byte_at(bytes, index) == '\n' {
			index
		} else {
			Nix.skip_assignment_comment(bytes, index + 1)
		}

	assignment_whitespace = |byte|
		byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r'

	assignment_byte_at = |bytes, index| bytes.get(index) ?? 0

	byte_slice = |bytes, start, end|
		Str.from_utf8(bytes.sublist({ start, len: end - start })) ?? ""

	assignment_error = |index, message|
		Err({ byte_offset: At(index), message })

	render_attribute_path : Str -> Str
	render_attribute_path = |path|
		Str.join_with(path.split_on(".").map(Nix.render_string), ".")

	render_string : Str -> Str
	render_string = |value| {
		escaped = Nix.escape_string_bytes(value.to_utf8(), 0, [])
		Str.join_with(["\"", Str.from_utf8(escaped) ?? "", "\""], "")
	}

	render_value_string = |value|
		if List.any(value.to_utf8(), Nix.needs_json_string_rendering) {
			json = Nix.render_string(Json.to_str(value))
			"(builtins.fromJSON ${json})"
		} else {
			Nix.render_string(value)
		}

	needs_json_string_rendering = |byte|
		byte < ' ' and byte != '\n' and byte != '\r' and byte != '\t'

	escape_string_bytes = |bytes, index, escaped|
		if index >= bytes.len() {
			escaped
		} else {
			byte = Nix.assignment_byte_at(bytes, index)
			if byte == '"' {
				Nix.escape_string_bytes(bytes, index + 1, escaped.concat(['\\', '"']))
			} else if byte == '\\' {
				Nix.escape_string_bytes(bytes, index + 1, escaped.concat(['\\', '\\']))
			} else if byte == '\n' {
				Nix.escape_string_bytes(bytes, index + 1, escaped.concat(['\\', 'n']))
			} else if byte == '\r' {
				Nix.escape_string_bytes(bytes, index + 1, escaped.concat(['\\', 'r']))
			} else if byte == '\t' {
				Nix.escape_string_bytes(bytes, index + 1, escaped.concat(['\\', 't']))
			} else if byte == '$' and
				Nix.assignment_byte_at(bytes, index + 1) == '{' {
				Nix.escape_string_bytes(
					bytes,
					index + 2,
					escaped.concat(['\\', '$', '{']),
				)
			} else {
				Nix.escape_string_bytes(bytes, index + 1, escaped.append(byte))
			}
		}

	render_scalar = |scalar|
		match scalar {
			NixBool(value) => if value "true" else "false"
			NixI64(value) => {
				raw = I64.to_str(value)
				if raw == "-9223372036854775808" {
					"(builtins.fromJSON \"-9223372036854775808\")"
				} else if value < 0 {
					"(${raw})"
				} else {
					raw
				}
			}
			NixString(value) => Nix.render_value_string(value)
		}

	render_value = |value|
		match value {
			NixScalarValue(scalar) => Nix.render_scalar(scalar)
			NixList(values) => Str.join_with(
				["[ ", Str.join_with(values.map(Nix.render_scalar), " "), " ]"],
				"",
			)
		}

	assignment_lines : List(Assignment) -> List(Str)
	assignment_lines = |assignments|
		assignments.map(
			|assignment|
				Str.join_with(
					[
						"  ",
						Nix.render_attribute_path(assignment.path),
						" = ",
						Nix.render_value(assignment.value),
						";",
					],
					"",
				),
		)

	assignment_module_lines : List(Assignment) -> List(Str)
	assignment_module_lines = |assignments|
		if assignments.is_empty() {
			[]
		} else {
			["  imports = [", "    {"]
				.concat(
					Nix.assignment_lines(assignments).map(|line| "    ${line}"),
				)
				.concat(["    }", "  ];"])
		}

	nix_interpolation : Str -> Str
	nix_interpolation = |expression| Str.join_with(["$", "{", expression, "}"], "")

	artifact_path_characters_message =
		\\artifact path may contain only ASCII letters, digits, '/', '.', '_', and '-'

	package_path_segments_message =
		\\shell package attribute paths must not contain empty segments

	unsafe_package_path_message =
		\\shell package attribute paths contain characters unsafe for Nix output

	unsafe_overlay_message =
		\\shell overlay references contain characters unsafe for Nix output

	artifact_path_rules : List(Plugin.TextRule)
	artifact_path_rules = [
		NonemptyText("artifact path must not be empty"),
		ForbiddenPathSegments({
			message: "artifact path must not contain '.' or '..' segments",
			segments: [".", ".."],
		}),
		AllBytes({
			allowed: [
				AsciiUppercase,
				AsciiLowercase,
				AsciiDigit,
				ExactByte('.'),
				ExactByte('_'),
				ExactByte('-'),
				ExactByte('/'),
			],
			message: artifact_path_characters_message,
		}),
	]

	package_rules : List(Plugin.StringListRule)
	package_rules = [
		AllStrings(NonemptyText("shell package names must not be empty")),
		AllStrings(
			DotSeparatedNonemptySegments(package_path_segments_message),
		),
		AllStrings(
			safe_string_rule(unsafe_package_path_message),
		),
	]

	overlay_rules : List(Plugin.StringListRule)
	overlay_rules = [
		AllStrings(NonemptyText("shell overlay references must not be empty")),
		AllStrings(
			safe_string_rule(unsafe_overlay_message),
		),
	]

	run : List(Str) -> Plugin.ExecutionStep
	run = |arguments| RunProgram({ arguments, program: backend.name })

	# SOPS is a secret-file encryption tool. In its binary JSON format, the
	# original file becomes one encrypted `data` value and `sops` holds metadata
	# such as the recipients that can unwrap the file's data key. This expression
	# checks that exact envelope without decrypting it.
	sops_binary_json_expression : Str
	sops_binary_json_expression =
		\\let
		\\  value = builtins.fromJSON (
		\\    builtins.readFile (builtins.getEnv "KAI_SECRET_FILE")
		\\  );
		\\in
		\\if builtins.isAttrs value
		\\  && builtins.attrNames value == [ "data" "sops" ]
		\\  && builtins.isString value.data
		\\  && builtins.match
		\\    "ENC[[]AES256_GCM,data:[^,]+,iv:[^,]+,tag:[^,]+,type:str[]]"
		\\    value.data != null
		\\then "true"
		\\else "false"

	# `filestatus` first asks SOPS whether the document is encrypted. That also
	# accepts structured JSON documents, so the Nix expression then narrows the
	# accepted shape to SOPS binary JSON. The executor runs both checks before
	# and after staging; neither validator needs the plaintext or private key.
	sops_binary_json_validators : List(Plugin.FileValidator)
	sops_binary_json_validators = [
		{
			arguments: [
				Literal("filestatus"),
				Literal("--input-type"),
				Literal("json"),
				StagedFilePath,
			],
			environment: NoFileEnvironment,
			expected_stdout: "{\"encrypted\":true}",
			program: "sops",
		},
		{
			arguments: [
				Literal("eval"),
				Literal("--impure"),
				Literal("--raw"),
				Literal("--expr"),
				Literal(Nix.sops_binary_json_expression),
			],
			environment: StagedFileEnvironment("KAI_SECRET_FILE"),
			expected_stdout: "true",
			program: "nix",
		},
	]

	render_nixos_module : List(Str), List(Str), List(Str), List(Assignment) -> Str
	render_nixos_module = |pkgs, users, services, assignments| {
		package_lines = pkgs.map(|pkg|
			"    pkgs.${Nix.render_attribute_path(pkg)}")
		user_lines = users.map(|user|
			"  users.users.\"${user}\".isNormalUser = true;")
		service_lines = services.map(
			|service|
				Str.join_with(
					[
						"  services.",
						Nix.render_attribute_path(service),
						".enable = true;",
					],
					"",
				),
		)
		lines = [
			"{ pkgs, ... }:",
			"{",
		].concat(Nix.assignment_module_lines(assignments)).concat([
			"  system.stateVersion = \"25.05\";",
			"  environment.systemPackages = [",
		]).concat(package_lines).concat([
			"  ];",
		]).concat(user_lines)
			.concat(service_lines)
			.concat([
				"}",
			])
		Str.join_with(lines, "\n")
	}

	lock_steps : Str -> List(Plugin.ExecutionStep)
	lock_steps = |flake_path|
		[
			Nix.run([
				"flake",
				"lock",
				"path:${flake_path}",
				"--reference-lock-file",
				"Kaifile.lock",
				"--output-lock-file",
				"Kaifile.lock",
			]),
			Nix.run([
				"flake",
				"lock",
				"path:${flake_path}",
				"--reference-lock-file",
				"Kaifile.lock",
				"--output-lock-file",
				"${flake_path}/flake.lock",
			]),
		]

}
