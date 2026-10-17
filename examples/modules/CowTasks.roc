# Settings are ordinary Roc values, so a module can share them: CowTasks gives
# any environment with cowsay the same tasks.
import std.Config
import std.EnvName

CowTasks :: [].{
	settings : EnvName -> List(Config.Setting)
	settings = |environment| [
		Task("moo", [Use(environment), Run(["cowsay", "moo"])]),
		Task("say", [Use(environment), Run(["cowsay"])]),
	]
}
