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

	render_attribute_path : Str -> Str
	render_attribute_path = |path|
		Str.join_with(path.split_on(".").map(|part| "\"${part}\""), ".")

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

	render_nixos_module : List(Str), List(Str), List(Str) -> Str
	render_nixos_module = |pkgs, users, services| {
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
			"  system.stateVersion = \"25.05\";",
			"  environment.systemPackages = [",
		].concat(package_lines).concat([
			"  ];",
		]).concat(user_lines).concat(service_lines).concat([
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
