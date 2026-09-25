# A fortune from a cow or a Pokémon: `kai run moo` or `kai run pika`.
app [config] { pf: platform "kaifile/platform/main.roc" }

config = [
	Name("kai"),
	Systems(["x86_64-linux"]),
	Environment("cow", [Tools(["cowsay", "fortune"])]),
	Environment("poke", [Tools(["pokemonsay", "fortune"])]),
	# Kai runs argv exactly, so the pipe needs an explicit shell.
	Task("moo", [Use("cow"), Run(["sh", "-c", "fortune | cowsay"])]),
	Task("pika", [Use("poke"), Run(["sh", "-c", "fortune | pokemonsay"])]),
]
