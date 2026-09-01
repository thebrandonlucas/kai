# Kaifile block schema for reproducible artifact builds.
import kai.Kaifile
import kai.Plugin
import Environment

Build := [].{
	inputs_field = Kaifile.optional("inputs", StringList)

	fields = [
		Kaifile.required_reference("environment", Environment.block),
		inputs_field,
		Kaifile.required("run", StringList),
		Kaifile.required("output", String),
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

	block : Plugin.Block
	block = Kaifile.named_block({
		header: "build <artifact>",
		fields,
		name_rules: artifact_name_rules,
	})

}
