# xkai entry point
app [main!] {
	pf: platform "../.basic-cli/main.roc",
}

import pf.Env
import pf.OsStr
import pf.Stderr
import pf.Stdout

import Builder
import Cli
import EmbeddedSources

print_usage! = |_| {
	Stdout.line!(Cli.usage)?
	Ok({})
}

main! = |args| {
	display_args = args.map(OsStr.display)
	match Cli.parse(display_args) {
		Cli.Command.Help => print_usage!({})
		Cli.Command.Version => {
			Stdout.line!("xkai version ${Cli.version}")?
			Ok({})
		}
		Cli.Command.Build(plugin_paths) =>
			match Env.var_str!(OsStr.utf8("XKAI_PLATFORM")) {
				Ok(path) =>
					Builder.build!(
						plugin_paths,
						EmbeddedSources.archive,
						{ platform_url: path },
					)
				Err(_) => {
					Stderr.line!(
						"error: set XKAI_PLATFORM to the basic-cli platform main.roc",
					)?
					Err(Exit(1))
				}
			}
		Cli.Command.Unknown(unknown) => {
			Stdout.line!("Unknown command ${unknown}")?
			print_usage!({})
		}
	}
}
