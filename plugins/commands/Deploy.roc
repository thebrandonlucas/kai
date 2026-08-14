import parser.Body
import kai.Plugin as PluginApi
import Build as BuildCommand

Deploy := [].{
	body : Body.Shape
	body = Body.object([
		Body.required("artifact", Identifier),
		Body.required("to", String),
	])

	name_rules : List(PluginApi.TextRule)
	name_rules = [
		NonemptyText("deployment name must not be empty"),
		DisallowedPrefix({ message: "deployment name must not start with '.'", prefix: "." }),
		AllBytes({
			allowed: [AsciiUppercase, AsciiLowercase, AsciiDigit, ExactByte(46), ExactByte(95), ExactByte(45)],
			message: "deployment name may contain only ASCII letters, digits, '.', '_', and '-'",
		}),
	]

	artifact_rules : List(PluginApi.TextRule)
	artifact_rules = BuildCommand.artifact_name_rules

	Destination := { store_url : Str, target : Str }

	parse_destination : Str -> Try(Destination, [InvalidDestination])
	parse_destination = |destination| {
		bytes = destination.to_utf8()
		if !destination.starts_with("ssh://") or bytes.len() <= 6 {
			Err(InvalidDestination)
		} else {
			remainder = Str.from_utf8(bytes.sublist({ start: 6, len: bytes.len() - 6 })) ?? ""
			match remainder.split_on("@") {
				[user, host] if Deploy.valid_user(user) and Deploy.valid_host(host) => {
					target = "${user}@${host}"
					Ok({ store_url: "ssh-ng://${target}", target })
				}
				_ => Err(InvalidDestination)
			}
		}
	}

	valid_user : Str -> Bool
	valid_user = |user| {
		bytes = user.to_utf8()
		match bytes {
			[first, .. as rest] => (Deploy.ascii_letter(first) or first == 95) and List.all(rest, Deploy.user_byte)
			[] => Bool.False
		}
	}

	user_byte : U8 -> Bool
	user_byte = |byte| Deploy.ascii_alphanumeric(byte) or byte == 46 or byte == 95 or byte == 45

	valid_host : Str -> Bool
	valid_host = |host|
		!host.is_empty() and List.all(host.split_on("."), Deploy.valid_host_label)

	valid_host_label : Str -> Bool
	valid_host_label = |label| {
		bytes = label.to_utf8()
		match bytes {
			[first, ..] =>
				Deploy.ascii_alphanumeric(first) and
					Deploy.ascii_alphanumeric(bytes.last() ?? 0) and
						List.all(bytes, |byte| Deploy.ascii_alphanumeric(byte) or byte == 45)
			[] => Bool.False
		}
	}

	ascii_letter : U8 -> Bool
	ascii_letter = |byte| (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)

	ascii_alphanumeric : U8 -> Bool
	ascii_alphanumeric = |byte| Deploy.ascii_letter(byte) or (byte >= 48 and byte <= 57)

	command : PluginApi.Command
	command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("deploy"),
		default_backend: "nix",
		name: "deploy",
	}

	rollback_command : PluginApi.Command
	rollback_command = PluginApi.Command.{
		argument_policy: AllowArguments,
		body,
		config_block: RequiredConfigBlock("deploy"),
		default_backend: "nix",
		name: "rollback",
	}
}

# -- TESTS --

name_cases = [
	{ expected: [], name: "production" },
	{ expected: [], name: "prod.eu_1-blue" },
	{ expected: ["deployment name must not be empty"], name: "" },
	{ expected: ["deployment name must not start with '.'"], name: ".production" },
	{
		expected: ["deployment name may contain only ASCII letters, digits, '.', '_', and '-'"],
		name: "prod/eu",
	},
]

expect List.all(name_cases, |case| PluginApi.validate_text(case.name, Deploy.name_rules) == case.expected)

artifact_cases = [
	{ artifact: "app", expected: [] },
	{ artifact: ".app", expected: ["artifact name must not start with '.'"] },
	{
		artifact: "app/path",
		expected: ["artifact name may contain only ASCII letters, digits, '.', '_', and '-'"],
	},
]

expect List.all(artifact_cases, |case| PluginApi.validate_text(case.artifact, Deploy.artifact_rules) == case.expected)

destination_cases = [
	{
		destination: "ssh://user@host",
		expected: Ok({ store_url: "ssh-ng://user@host", target: "user@host" }),
	},
	{
		destination: "ssh://_deploy.name@host-1.example.com",
		expected: Ok({ store_url: "ssh-ng://_deploy.name@host-1.example.com", target: "_deploy.name@host-1.example.com" }),
	},
	{ destination: "ssh://9user@host", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@-host", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host-", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host..example", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host:22", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@[::1]", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host/path", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host?key=value", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host#fragment", expected: Err(InvalidDestination) },
	{ destination: "ssh://user%40other@host", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host name", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@host;touch", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@@host", expected: Err(InvalidDestination) },
	{ destination: "http://user@host", expected: Err(InvalidDestination) },
	{ destination: "ssh://user@", expected: Err(InvalidDestination) },
]

expect List.all(destination_cases, |case| Deploy.parse_destination(case.destination) == case.expected)

artifact_reference_cases = ["app", "1app", "-app"]

expect List.all(
	artifact_reference_cases,
	|artifact|
		match Body.parse(Deploy.body, "artifact: ${artifact}\nto: \"ssh://user@host\"") {
			Ok(config) => Body.get_string(config, "artifact") == Ok(artifact) and Body.get_string(config, "to") == Ok("ssh://user@host")
			Err(_) => Bool.False
		},
)
