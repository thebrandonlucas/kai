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
			message: Str.join_with(
				[
					"artifact path may contain only ASCII letters, digits, ",
					"'/', '.', '_', and '-'",
				],
				"",
			),
		}),
	]

	package_rules : List(Plugin.StringListRule)
	package_rules = [
		AllStrings(NonemptyText("shell package names must not be empty")),
		AllStrings(
			DotSeparatedNonemptySegments(
				Str.join_with(
					[
						"shell package attribute paths must not contain ",
						"empty segments",
					],
					"",
				),
			),
		),
		AllStrings(
			safe_string_rule(
				Str.join_with(
					[
						"shell package attribute paths contain characters ",
						"unsafe for Nix output",
					],
					"",
				),
			),
		),
	]

	overlay_rules : List(Plugin.StringListRule)
	overlay_rules = [
		AllStrings(NonemptyText("shell overlay references must not be empty")),
		AllStrings(
			safe_string_rule(
				Str.join_with(
					[
						"shell overlay references contain characters unsafe ",
						"for Nix output",
					],
					"",
				),
			),
		),
	]

	run : List(Str) -> Plugin.ExecutionStep
	run = |arguments| RunProgram({ arguments, program: backend.name })

	lock_steps : Str -> List(Plugin.ExecutionStep)
	lock_steps = |flake_path|
		[
			Nix.run([
				"flake",
				"lock",
				"path:${flake_path}",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"kai.lock",
			]),
			Nix.run([
				"flake",
				"lock",
				"path:${flake_path}",
				"--reference-lock-file",
				"kai.lock",
				"--output-lock-file",
				"${flake_path}/flake.lock",
			]),
		]

}
