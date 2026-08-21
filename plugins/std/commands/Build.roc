import parser.Body
import parser.Bytes
import kai.Plugin

Build := [].{
	body : Body.Shape
	body = Body.object([
		Body.required("environment", Identifier),
		Body.required("run", StringList),
		Body.required("output", String),
	])

	artifact_name_rules : List(Plugin.TextRule)
	artifact_name_rules = [
		NonemptyText("artifact name must not be empty"),
		DisallowedPrefix({ message: "artifact name must not start with '.'", prefix: "." }),
		AllBytes({
			allowed: [AsciiUppercase, AsciiLowercase, AsciiDigit, ExactByte(Bytes.period), ExactByte(Bytes.underscore), ExactByte(Bytes.hyphen)],
			message: "artifact name may contain only ASCII letters, digits, '.', '_', and '-'",
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

	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("build"),
		name: "build",
	}
}
