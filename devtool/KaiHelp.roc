# Run what a built kai's help teaches: gather every command's examples and
# Kaifile.roc settings from its plain help, compile the settings as one real
# Kaifile.roc, then run each non-interactive example against real Nix.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout

import ConfigFixtures

KaiHelp := [].{
	run! = |binary| {
		root = Path.canonicalize!(Env.cwd!()?)?
		kai = Path.canonicalize!(Path.utf8(binary))?
		project = Path.canonicalize!(
			Env.create_temp_dir_with_prefix!("kai-help-")?,
		)?
		result = KaiHelp.run_in!(root, kai, project)
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
		KaiHelp.section(text, "Commands:")
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
		# Output to a pipe is plain even without --no-color.
		top = kai!(["--help"])?.stdout_utf8
		names = KaiHelp.commands(top)
		if names.is_empty() {
			return Err(NoCommandsInHelp(top))
		}
		var $examples = KaiHelp.section(top, "Examples:")
		var $settings = KaiHelp.section(top, "Kaifile.roc (inside config):")
		for name in names {
			page = kai!([name, "--help"])?.stdout_utf8
			found = KaiHelp.section(page, "Examples:")
			if found.is_empty() or page.contains("\u(001b)") {
				return Err(BadCommandHelp(name, page))
			}
			$examples = KaiHelp.add_new($examples, found)
			$settings = KaiHelp.add_new(
				$settings,
				KaiHelp.section(page, "Kaifile.roc (inside config):"),
			)
		}
		platform_path = ConfigFixtures.relative(
			Path.display(project),
			Path.display(Path.join(root, "kaifile/platform/main.roc")),
		)
		lines = ["Name(\"help\"),", "Systems([\"x86_64-linux\"]),"]
			.concat($settings)
			.map(|line| "\t${line}")
		header = "app [config] { pf: platform \"${platform_path}\" }"
		kaifile = Str.join_with(
			[header, "", "config = ["].concat(lines).concat(["]", ""]),
			"\n",
		)
		Path.write_utf8!(Path.join(project, "Kaifile.roc"), kaifile)?
		_ = kai!(["update"])?
		for example in $examples {
			args = example.split_on(" ").drop_first(1)
			if KaiHelp.runnable(args) {
				_ = kai!(args)
					.map_err(|err| ExampleFailed(example, Str.inspect(err)))?
			}
		}
		Stdout.line!("kai help examples compile and run")
	}
}
