# Reusable tasks; the caller supplies the environment identity.
import pf.Config
import pf.EnvName

## A normal pure function can supply reusable settings. It neither installs
## tools nor extends the consumer with a new backend or runtime operation.
ProjectTasks :: [].{
	settings : EnvName -> List(Config.Setting)
	settings = |environment| [
		Task("fmt", [Use(environment), Run(["git", "diff", "--check"])]),
		Task("test", [Use(environment), Run(["git", "--version"])]),
		# Prints each argument in brackets, so argv boundaries stay visible.
		Task(
			"args",
			[
				Use(environment),
				Run([
					"sh",
					"-c",
					"printf '<%s>' \"$@\"; echo",
					"args",
					"configured argument",
				]),
			],
		),
	]
}
