# std's settings are today's Kaifile settings. Until std plans its commands
# itself, it describes the project with their Kaifile IR, which kai plans
# from.
import pf.Config
import pf.Kaifile
import pf.Lower
import pf.Plugin

Std := [].{

	## The usual Kaifile.roc: std alone.
	kaifile : List(Config.Setting) -> Kaifile
	kaifile = |settings| Kaifile.new([Std.plugin(settings)])

	## Invalid settings become the plugin's problems, so Kaifile.roc fails
	## to compile.
	plugin : List(Config.Setting) -> Plugin
	plugin = |settings|
		match Lower.render(settings) {
			Ok(describe) => Plugin.new({ name: "std", version: "", describe })
			Err(problem) => Plugin.invalid("std", [problem])
		}
}

# Valid settings describe the project; invalid ones name std's problem.
expect {
	valid = Kaifile.validate(Std.kaifile([Name("x")]))
	valid.map_ok(|ir| ir.contains("(name \"x\")")) == Ok(Bool.True)
		and Kaifile.validate(Std.kaifile([]))
			== Err("std: MissingName: declare Name once")
}
