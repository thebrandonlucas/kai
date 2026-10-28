# A command a plugin adds to kai: its name, help and arguments, as data the
# platform builds kai's parser and help from. Plugins never parse argv.

## `OwnsLock` lets the command's plans publish the lock (`PublishLock`).
Command := {
	name : Str,
	summary : Str,
	help : Page,
	args : List(Arg),
	lock : [ReadsLock, OwnsLock],
}.{

	## What the command accomplishes, commands to try, and the Kaifile.roc
	## lines that make them work.
	Page : { description : Str, examples : List(Str), config : List(Str) }

	## At most one `Name` then at most one `Trailing`, in that order, and
	## any `Flag`s and `Path`s, given anywhere before `--`.
	Arg := [
		## A name chosen from the project; each choice becomes a subcommand
		## so help lists it. No choices means any name.
		Name(
			{
				name : Str,
				help : Str,
				choices : List(Choice),
				default : [Required, Default(Str)],
			},
		),

		## Everything after `--`, exact. Choices restrict the words to the
		## project's names; no choices means any words.
		Trailing({ name : Str, help : Str, choices : List(Choice) }),

		## `--name`, or `-short` unless "": given or not.
		Flag({ name : Str, short : Str, help : Str }),

		## `--name PATH`, optional. A relative PATH is resolved against the
		## directory kai runs in, so plugins see it absolute.
		Path({ name : Str, short : Str, help : Str }),
	]

	## One project entry, for help: `kai run test --help` shows `details`.
	Choice : { value : Str, summary : Str, details : List(Str) }

	## Parsed arguments by name; a required `Name` is always present.
	Args : List({ name : Str, value : [Present(Str), Many(List(Str))] })

	## The value of a `Name` argument, or "" when absent.
	name : Args, Str -> Str
	name = |args, wanted|
		match args.find_first(|a| a.name == wanted) {
			Ok({ value: Present(value), .. }) => value
			_ => ""
		}

	## Whether a `Flag` was given.
	flag : Args, Str -> Bool
	flag = |args, wanted| args.any(|a| a.name == wanted)

	## The absolute path a `Path` argument names, if given.
	path : Args, Str -> Try(Str, [NoValue])
	path = |args, wanted|
		match args.find_first(|a| a.name == wanted) {
			Ok({ value: Present(value), .. }) => Ok(value)
			_ => Err(NoValue)
		}

	## The words of a `Trailing` argument, or [] when absent.
	trailing : Args, Str -> List(Str)
	trailing = |args, wanted|
		match args.find_first(|a| a.name == wanted) {
			Ok({ value: Many(words), .. }) => words
			_ => []
		}
}
