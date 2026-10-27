# Tasks are named commands that run in an environment: `kai run moo` makes
# the cow say a pithy quote. Arguments after `--` are appended to the task.
# `kai run --help` lists each task with its Description, else its command;
# `kai run moo --help` shows both.
app [kaifile] {
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import std.Std

kaifile = Std.kaifile([
	Name("task"),
	Systems(["x86_64-linux", "aarch64-linux"]),
	Environment("cow", [Tools(["cowsay", "fortune"])]),
	Task(
		"moo",
		[
			Use("cow"),
			Description("The cow says a pithy quote"),
			Run(["sh", "-c", "fortune | cowsay"]),
		],
	),
	Task("say", [Use("cow"), Run(["cowsay"])]),
	# `kai run whisper` needs COW_SECRET from a `.env` line such as
	# `COW_SECRET=moo`, or from kai's environment; no other task sees it.
	Task(
		"whisper",
		[
			Use("cow"),
			Secrets(["COW_SECRET"]),
			Run(["sh", "-c", "cowsay \"$COW_SECRET\""]),
		],
	),
	# `COW_NAME=Daisy kai run greet` passes COW_NAME from kai's environment;
	# unlike a secret, it may be unset, and other tasks still receive it.
	Task(
		"greet",
		[
			Use("cow"),
			OptionalEnvironmentVariables(["COW_NAME"]),
			Run(["sh", "-c", "cowsay \"hello $COW_NAME\""]),
		],
	),
])
