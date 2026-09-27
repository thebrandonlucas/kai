# What a Kaifile.roc provides: its plugins, checked while it compiles.
import Plugin

Kaifile := { plugins : List(Plugin) }.{
	new : List(Plugin) -> Kaifile
	new = |plugins| Kaifile.{ plugins }

	## The project description kai reads, or why the plugins are invalid:
	## a plugin's problems, a plugin named twice, or not exactly one plugin
	## describing the project.
	validate : Kaifile -> Try(Str, Str)
	validate = |kaifile| {
		var $names = []
		for plugin in kaifile.plugins {
			match plugin.problems {
				[] => {}
				problems => {
					reasons = Str.join_with(problems, "; ")
					return Err("${plugin.name}: ${reasons}")
				}
			}
			if $names.contains(plugin.name) {
				return Err("plugin ${plugin.name} is listed twice")
			}
			$names = $names.append(plugin.name)
		}
		match kaifile.plugins.keep_if(|p| !p.describe.is_empty()) {
			[one] => Ok(one.describe)
			[] => Err("no plugin describes the project")
			_ => Err("more than one plugin describes the project")
		}
	}
}

described = |name, text| Plugin.new({ name, version: "1", describe: text })

# One describing plugin is the description; problems, repeated names and
# zero or several descriptions are refused.
expect [
	([described("std", "(ir)")], Ok("(ir)")),
	([described("std", "(ir)"), described("x", "")], Ok("(ir)")),
	(
		[Plugin.invalid("std", ["no Name", "two Systems"])],
		Err("std: no Name; two Systems"),
	),
	(
		[described("std", "(ir)"), described("std", "")],
		Err("plugin std is listed twice"),
	),
	([described("x", "")], Err("no plugin describes the project")),
	(
		[described("std", "(a)"), described("y", "(b)")],
		Err("more than one plugin describes the project"),
	),
].all(|(plugins, expected)| Kaifile.validate(Kaifile.new(plugins)) == expected)
