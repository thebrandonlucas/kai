import parser.Body
import parser.Bytes
import kai.Plugin

Secret := [].{
	body : Body.Shape
	body = Body.object([Body.required("provision", Identifier)])

	name_rules : List(Plugin.TextRule)
	name_rules = [
		NonemptyText("secret name must not be empty"),
		AllBytes({
			allowed: [AsciiUppercase, AsciiLowercase, AsciiDigit, ExactByte(Bytes.underscore), ExactByte(Bytes.hyphen)],
			message: "secret name may contain only ASCII letters, digits, '_', and '-'",
		}),
	]

	name_failures : Str -> List(Str)
	name_failures = |name| {
		length_failures = if name.to_utf8().len() <= 128 [] else ["secret name must be at most 128 bytes"]
		Plugin.validate_text(name, Secret.name_rules).concat(length_failures)
	}

	provision_failures : Str -> List(Str)
	provision_failures = |provision|
		if provision == "runtime" [] else ["secret provision must be 'runtime'"]

	descriptor : Plugin.ProjectConfigDescriptor
	descriptor = { block: "secret", body, kind: NamedProjectConfig }
}
