# Reusable tasks; the caller supplies the environment identity.
import pf.Config
import pf.EnvName

## A normal pure function can supply reusable settings. It neither installs
## tools nor extends the consumer with a new backend or runtime operation.
ProjectTasks :: [].{
	settings : EnvName -> List(Config.Setting)
	settings = |environment| [
		Task("fmt", [Use(environment), Run(["python3", "--version"])]),
		Task("test", [Use(environment), Run(["git", "--version"])]),
		Task(
			"args",
			[
				Use(environment),
				Run([
					"python3",
					"-c",
					"import json, sys; print(json.dumps(sys.argv[1:]))",
					"configured argument",
				]),
			],
		),
	]
}
