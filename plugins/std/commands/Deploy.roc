# Defines named remote machine deployments.
import parser.Fields
import kai.Kaifile
import kai.Plugin

Deploy := [].{
	fields = [
		Fields.required("artifact", String),
		Fields.required("to", String),
	]

	name_rules : List(Plugin.TextRule)
	name_rules = [
		NonemptyText("deployment name must not be empty"),
		DisallowedPrefix({
			message: "deployment name must not start with '.'",
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
					"deployment name may contain only ASCII letters, digits, ",
					"'.', '_', and '-'",
				],
				"",
			),
		}),
	]

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({
		header: "deploy <deployment>",
		fields,
		name_rules,
	})

	Destination := { store_url : Str, target : Str }

	parse_destination : Str -> Try(Destination, [InvalidDestination])
	parse_destination = |destination| {
		bytes = destination.to_utf8()
		if !destination.starts_with("ssh://") or bytes.len() <= 6 {
			Err(InvalidDestination)
		} else {
			remainder = Str.from_utf8(
				bytes.sublist({ start: 6, len: bytes.len() - 6 }),
			) ?? ""
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
			[first, .. as rest] =>
				(Deploy.ascii_letter(first) or first == '_') and
					List.all(rest, Deploy.user_byte)
			[] => Bool.False
		}
	}

	user_byte = |byte|
		Deploy.ascii_alphanumeric(byte) or
			byte == '.' or
				byte == '_' or
					byte == '-'

	valid_host : Str -> Bool
	valid_host = |host|
		!host.is_empty() and
			List.all(host.split_on("."), Deploy.valid_host_label)

	valid_host_label : Str -> Bool
	valid_host_label = |label| {
		bytes = label.to_utf8()
		match bytes {
			[first, ..] =>
				Deploy.ascii_alphanumeric(first) and
					Deploy.ascii_alphanumeric(bytes.last() ?? 0) and
						List.all(
							bytes,
							|byte| Deploy.ascii_alphanumeric(byte) or byte == '-',
						)
			[] => Bool.False
		}
	}

	ascii_letter = |byte|
		(byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z')

	ascii_alphanumeric = |byte|
		Deploy.ascii_letter(byte) or (byte >= '0' and byte <= '9')

	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("deploy", [Plugin.required_argument("deployment")]),
		config: NamedConfig({ lookup: QualifiedThenUnqualified }),
		config_block: RequiredConfigBlock(block),
	}
}
