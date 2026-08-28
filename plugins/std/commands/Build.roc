# Shared interface for `build` artifact/executable commands
import parser.Body
import kai.Kaifile
import kai.Plugin

Build := [].{
	inputs_field = Body.optional("inputs", StringList)

	fields = [
		Body.required("environment", Identifier),
		inputs_field,
		Body.required("run", StringList),
		Body.required("output", String),
	]

	artifact_name_rules : List(Plugin.TextRule)
	artifact_name_rules = [
		NonemptyText("artifact name must not be empty"),
		DisallowedPrefix({
			message: "artifact name must not start with '.'",
			prefix: ".",
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
					"artifact name may contain only ASCII letters, digits, ",
					"'.', '_', and '-'",
				],
				"",
			),
		}),
	]

	run_rules : List(Plugin.StringListRule)
	run_rules = [
		NonemptyStringList("build run list must not be empty"),
		NonemptyFirstString("build run program must not be empty"),
	]

	output_rules : List(Plugin.TextRule)
	output_rules = [
		NonemptyText("build output must not be empty"),
		DisallowedPrefix({ message: "build output must be relative", prefix: "/" }),
		ForbiddenPathSegments({
			message: "build output must not contain '.' or '..' path segments",
			segments: [".", ".."],
		}),
	]

	environment_rules : Str -> List(Plugin.TextRule)
	environment_rules = |artifact_name|
		[NonemptyText("build '${artifact_name}' environment name must not be empty")]

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({
		header: "build <artifact>",
		fields,
		name_rules: artifact_name_rules,
	})

	environment_block : Plugin.KaifileBlock
	environment_block = Kaifile.named_block({
		header: "environment <environment>",
		fields: [
			Body.required("packages", StringList),
			Body.optional("overlays", StringList),
		],
		name_rules: [],
	})

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("build", [Plugin.required_argument("artifact")]),
		config: NamedWithRelatedConfig({
			lookup: QualifiedThenUnqualified,
			related: environment_block,
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock(block),
	}
}
