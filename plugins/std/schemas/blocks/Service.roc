# Kaifile block schema for machine services.
import kai.Kaifile
import kai.Plugin
import Secret

Service := [].{
	fields = [
		Kaifile.required("artifact", String),
		Kaifile.required("secrets", StringList),
		Kaifile.required("restart", Identifier),
	]

	name_rules : List(Plugin.TextRule)
	name_rules = [
		NonemptyText("service name must not be empty"),
		AllBytes({
			allowed: [
				AsciiUppercase,
				AsciiLowercase,
				AsciiDigit,
				ExactByte('_'),
				ExactByte('-'),
			],
			message: "service name may contain only ASCII letters, digits, '_', and '-'",
		}),
	]

	name_failures : Str -> List(Str)
	name_failures = |name| {
		length_failures = if name.to_utf8().len() <= 128 {
			[]
		} else {
			["service name must be at most 128 bytes"]
		}
		Plugin.validate_text(name, Service.name_rules).concat(length_failures)
	}

	secret_failures : List(Str) -> List(Str)
	secret_failures = |secrets| {
		validation_failures = Plugin.validate_string_list(
			secrets,
			Secret.name_rules.map(|rule| AllStrings(rule)),
		)
		length_failures = if List.any(
			secrets,
			|secret| secret.to_utf8().len() > 128,
		) {
			["secret name must be at most 128 bytes"]
		} else {
			[]
		}
		duplicate_failures = if Service.has_duplicates(secrets) {
			["service secret references must not contain duplicates"]
		} else {
			[]
		}
		validation_failures.concat(length_failures).concat(duplicate_failures)
	}

	has_duplicates : List(Str) -> Bool
	has_duplicates = |values|
		match values {
			[] => Bool.False
			[first, .. as rest] => rest.contains(first) or Service.has_duplicates(rest)
		}

	restart_failures : Str -> List(Str)
	restart_failures = |restart|
		if restart == "on-failure" [] else ["service restart must be 'on-failure'"]

	block : Plugin.Block
	block = Kaifile.named_block({
		header: "service <service>",
		fields,
		name_rules,
	})

}
