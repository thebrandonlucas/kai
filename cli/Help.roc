# kai's own help: the header a Kaifile.roc starts with, and what kai says
# when there is no Kaifile.roc to ask. Command help comes from the Kaifile's
# plugins.
import "../platform-release" as platform_release : Str
import "../plugins/std-release" as std_release : Str

Help := [].{
	# How a Kaifile.roc starts: with the platform and std bundles this Kai's
	# release publishes. Each URL is one unbroken line, however help wraps.
	header =
		"app [kaifile] {\npf: platform \"${platform_release.trim()}\",\n"
			.concat("std: \"${std_release.trim()}\",\n}\n\nimport std.Std\n\n")
			.concat("kaifile = Std.kaifile([...])")

	# Shown when Kaifile.roc is missing or does not compile, since its
	# plugins define the commands.
	generic : Str, Str -> Str
	generic = |version, why|
		"kai ${version}"
			.concat("\n\nDeveloper environments, tasks and builds from a Kaifile.roc.")
			.concat("\n\n${why}")
			.concat("\n\nKaifile.roc starts with:\n${Help.header}")
			.concat("\n\nUsage:\n  kai [-f/--file PATH] [--json] check")
			.concat("\n  kai [OPTIONS] <COMMAND> --help")
			.concat("\n\nSet ROC to choose the Roc compiler (default: roc).")

	# Color is decoration only: NO_COLOR (when non-empty), --no-color or output
	# that is not a terminal all get plain text.
	text_style : { terminal : Bool, no_color : Str, flag : Bool } -> [Color, Plain]
	text_style = |{ terminal, no_color, flag }|
		if terminal and no_color.is_empty() and !flag Color else Plain
}

# Only an interactive terminal without an opt-out gets color.
expect [
	({ terminal: Bool.True, no_color: "", flag: Bool.False }, Color),
	({ terminal: Bool.False, no_color: "", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "1", flag: Bool.False }, Plain),
	({ terminal: Bool.True, no_color: "", flag: Bool.True }, Plain),
	({ terminal: Bool.False, no_color: "1", flag: Bool.True }, Plain),
].all(|(input, expected)| Help.text_style(input) == expected)
