import parser.Body
import kai.Plugin

Machine := [].{
	body : Body.Shape
	body = Body.object([
		Body.required("environment", Identifier),
		Body.required("system", String),
		Body.optional("users", StringList),
		Body.optional("services", StringList),
	])

	name_rules : List(Plugin.TextRule)
	name_rules = [
		NonemptyText("machine name must not be empty"),
		DisallowedPrefix({ message: "machine name must not start with '.'", prefix: "." }),
		AllBytes({
			allowed: [AsciiUppercase, AsciiLowercase, AsciiDigit, ExactByte('.'), ExactByte('_'), ExactByte('-')],
			message: "machine name may contain only ASCII letters, digits, '.', '_', and '-'",
		}),
	]

	service_rules : List(Plugin.StringListRule)
	service_rules = [
		AllStrings(NonemptyText("machine service names must not be empty")),
		AllStrings(DotSeparatedNonemptySegments("machine service names must not contain empty segments")),
		AllStrings(
			AllBytes({
				allowed: [AsciiUppercase, AsciiLowercase, AsciiDigit, ExactByte('.'), ExactByte('_'), ExactByte('-')],
				message: "machine service names may contain only ASCII letters, digits, '.', '_', and '-'",
			}),
		),
	]

	valid_user : Str -> Bool
	valid_user = |user|
		match user.to_utf8() {
			[first, .. as rest] =>
				(Machine.ascii_lower(first) or first == '_') and
					List.all(rest, |byte| Machine.ascii_lower(byte) or Machine.ascii_digit(byte) or byte == '_' or byte == '-')
			[] => Bool.False
		}

	ascii_lower = |byte| byte >= 97 and byte <= 122
	ascii_digit = |byte| byte >= 48 and byte <= 57

	has_duplicates : List(Str) -> Bool
	has_duplicates = |values|
		match values {
			[] => Bool.False
			[first, .. as rest] => rest.contains(first) or Machine.has_duplicates(rest)
		}

	user_failures : List(Str) -> List(Str)
	user_failures = |users| {
		invalid = if List.all(users, Machine.valid_user) [] else ["machine users must match [a-z_][a-z0-9_-]*"]
		reserved = users.keep_if(|user| user == "root" or user == "nobody")
		reserved_failures = reserved.map(|user| "machine user '${user}' is unsupported because NixOS already defines it")
		duplicates = if Machine.has_duplicates(users) ["machine users must not contain duplicates"] else []
		invalid.concat(reserved_failures).concat(duplicates)
	}

	service_failures : List(Str) -> List(Str)
	service_failures = |services| {
		invalid = Plugin.validate_string_list(services, Machine.service_rules)
		duplicates = if Machine.has_duplicates(services) ["machine services must not contain duplicates"] else []
		invalid.concat(duplicates)
	}

	command : Plugin.Command
	command = Plugin.Command.{
		argument_policy: AllowArguments,
		body,
		config: NamedWithRelatedConfig({
			lookup: QualifiedThenUnqualified,
			name_rules,
			related_block: "environment",
			related_body: Body.object([
				Body.required("packages", StringList),
				Body.optional("overlays", StringList),
			]),
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock("machine"),
		name: "machine",
	}
}
