# Render plugin planning failures for human-readable CLI output.
import Plugin

PlanningError := [].{
	argument_usage : List(Plugin.CommandHelpArgument) -> Str
	argument_usage = |arguments|
		match arguments {
			[] => ""
			[first, .. as rest] => {
				argument = match first.presence {
					OptionalHelpArgument => " [${first.name}]"
					RequiredHelpArgument => " <${first.name}>"
				}
				"${argument}${PlanningError.argument_usage(rest)}"
			}
		}

	render_source_context : Str, Str, Plugin.SourceLocation -> Str
	render_source_context = |kaifile_path, kaifile_source, location| {
		line_number = U64.to_str(location.line)
		column_number = U64.to_str(location.column)
		line_index = location.line - 1
		source_line = kaifile_source.split_on("\n").get(line_index) ?? ""
		gutter_padding = " ".repeat(line_number.to_utf8().len())
		caret_padding = " ".repeat(location.column - 1)
		\\  --> ${kaifile_path}:${line_number}:${column_number}
		\\${gutter_padding} |
		\\${line_number} | ${source_line}
		\\${gutter_padding} | ${caret_padding}^
	}

	planning_error :
		Str, Str, List(Plugin.Definition), Plugin.PlanningDiagnostic -> Str
	planning_error = |kaifile, kaifile_text, registry, diagnostic| {
		context = match diagnostic.location {
			At(source) =>
				"\n${PlanningError.render_source_context(kaifile, kaifile_text, source)}"
			None =>
				match Plugin.find_owner(registry, diagnostic.command) {
					Err(UnknownCommand) => ""
					Ok(matching_command_and_definition) => {
						matching_command = matching_command_and_definition.command
						command = Plugin.syntax_from_command(matching_command)
						match command.help {
							NoCommandHelp => ""
							CommandHelpAvailable(help_content) => {
								arguments = PlanningError.argument_usage(help_content.arguments)
								usage = "\nusage: kai ${command.name}${arguments}"
								match help_content.examples {
									[] => usage
									[example, ..] => "${usage}\nexample: ${example}"
								}
							}
						}
					}
				}
			}
		"error: ${diagnostic.message}${context}"
	}
}
