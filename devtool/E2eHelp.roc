# Run what a built kai's help teaches: gather every command's examples and
# Kaifile.roc settings from its plain help, compile the settings as one real
# Kaifile.roc, then run each non-interactive example against real Nix.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout

import ConfigFixtures

E2eHelp := [].{
	nix! = |binary| {
		root = Path.canonicalize!(Env.cwd!()?)?
		kai = Path.canonicalize!(Path.utf8(binary))?
		project = Path.canonicalize!(
			Env.create_temp_dir_with_prefix!("kai-help-")?,
		)?
		result = E2eHelp.run_in!(root, kai, project)
		Path.delete_all!(project)?
		result
	}

	# Lines under a help heading, up to the next blank line.
	section : Str, Str -> List(Str)
	section = |text, heading|
		match text.split_on("\n${heading}\n") {
			[_, after] => (after.split_on("\n\n").first() ?? "").split_on("\n")
			_ => []
		}

	# Command names start a Commands row; wrapped descriptions are indented.
	commands : Str -> List(Str)
	commands = |text|
		E2eHelp.section(text, "Commands:")
			.map(|line| line.drop_prefix("  "))
			.keep_if(|line| !line.starts_with(" "))
			.map(|line| line.split_on(" ").first() ?? line)

	add_new : List(Str), List(Str) -> List(Str)
	add_new = |kept, lines|
		lines.fold(kept, |acc, line| if acc.contains(line) acc else acc.append(line))

	# Without a command, kai shell is interactive; update runs first anyway.
	runnable : List(Str) -> Bool
	runnable = |args|
		match args {
			["shell", ..] => args.contains("--")
			["update"] => Bool.False
			_ => Bool.True
		}

	run_in! = |root, kai, project| {
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(project)
			.exec_output!()
		# Commands and their help come from the Kaifile's plugins.
		write! = |settings| {
			systems = "Systems([\"x86_64-linux\", \"aarch64-linux\"]),"
			lines = ["Name(\"help\"),", systems]
				.concat(settings)
				.map(|line| "\t${line}")
			header = ConfigFixtures.header(root, project)
			kaifile = Str.join_with(
				[header, "", "import std.Std", "", "kaifile = Std.kaifile(["]
					.concat(lines)
					.concat(["])", ""]),
				"\n",
			)
			Path.write_utf8!(Path.join(project, "Kaifile.roc"), kaifile)
		}
		write!([])?
		# Output to a pipe is plain even without --no-color.
		top = kai!(["--help"])?.stdout_utf8
		names = E2eHelp.commands(top)
		if names.is_empty() {
			return Err(NoCommandsInHelp(top))
		}
		var $examples = E2eHelp.section(top, "Examples:")
		var $settings = E2eHelp.section(top, "Kaifile.roc (inside Std.kaifile):")
		for name in names {
			page = kai!([name, "--help"])?.stdout_utf8
			found = E2eHelp.section(page, "Examples:")
			if found.is_empty() or page.contains("\u(001b)") {
				return Err(BadCommandHelp(name, page))
			}
			$examples = E2eHelp.add_new($examples, found)
			$settings = E2eHelp.add_new(
				$settings,
				E2eHelp.section(page, "Kaifile.roc (inside Std.kaifile):"),
			)
		}
		write!($settings)?
		_ = kai!(["update"])?
		for example in $examples {
			args = example.split_on(" ").drop_first(1)
			if E2eHelp.runnable(args) {
				_ = kai!(args)
					.map_err(|err| ExampleFailed(example, Str.inspect(err)))?
			}
		}
		Stdout.line!("kai help examples compile and run")
	}
}
