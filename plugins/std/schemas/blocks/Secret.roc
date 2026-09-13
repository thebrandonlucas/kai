# Shared `command` interface for defining and working with environment
# secrets.
import kai.Kaifile
import kai.Plugin

Secret := [].{
	name_rules : List(Plugin.TextRule)
	name_rules = [
		NonemptyText("secret name must not be empty"),
		AllBytes({
			allowed: [
				AsciiUppercase,
				AsciiLowercase,
				AsciiDigit,
				ExactByte('_'),
				ExactByte('-'),
			],
			message: "secret name may contain only ASCII letters, digits, '_', and '-'",
		}),
	]

	name_failures : Str -> List(Str)
	name_failures = |name| {
		length_failures = if name.to_utf8().len() <= 128 {
			[]
		} else {
			["secret name must be at most 128 bytes"]
		}
		Plugin.validate_text(name, Secret.name_rules).concat(length_failures)
	}

	provider_failures : Str -> List(Str)
	provider_failures = |provider|
		if provider == "sops" [] else ["secret provider must be 'sops'"]

	file_rules : List(Plugin.TextRule)
	file_rules = [
		NonemptyText("secret file must not be empty"),
		DisallowedPrefix({ message: "secret file must be relative", prefix: "/" }),
		DisallowedPrefix({
			message: "secret file must not start with '-'",
			prefix: "-",
		}),
		ForbiddenPathSegments({
			message: "secret file must not contain '.' or '..' path segments",
			segments: [".", ".."],
		}),
		AllBytes({
			allowed: [
				AsciiUppercase,
				AsciiLowercase,
				AsciiDigit,
				ExactByte('.'),
				ExactByte('/'),
				ExactByte('_'),
				ExactByte('-'),
			],
			message: Str.join_with(
				[
					"secret file may contain only ASCII letters, digits, ",
					"'/', '.', '_', and '-'",
				],
				"",
			),
		}),
	]

	file_failures : Str -> List(Str)
	file_failures = |file| {
		empty_segment_failures = if file.is_empty() or List.all(
			file.split_on("/"),
			|segment| !segment.is_empty(),
		) {
			[]
		} else {
			["secret file must not contain empty '/' path segments"]
		}
		format_failures = if file.is_empty() or file.ends_with(".json") {
			[]
		} else {
			[
				Str.join_with(
					[
						"secret file must end with '.json'; the MVP accepts only ",
						"SOPS binary documents encoded as JSON",
					],
					"",
				),
			]
		}
		length_failures = if file.to_utf8().len() <= 512 {
			[]
		} else {
			["secret file must be at most 512 bytes"]
		}
		Plugin.validate_text(file, Secret.file_rules)
			.concat(empty_segment_failures)
			.concat(format_failures)
			.concat(length_failures)
	}

	workspace_file_failures : Str, Str -> List(Str)
	workspace_file_failures = |file, workspace_root|
		if file == workspace_root or file.starts_with("${workspace_root}/") {
			["secret file must not be under workspace root '${workspace_root}'"]
		} else {
			[]
		}

	block : Plugin.Block
	block = Kaifile.named_block({
		header: "secret <secret>",
		fields: [
			Kaifile.required("provider", Identifier),
			Kaifile.required("file", String),
		],
		name_rules,
	})

}
