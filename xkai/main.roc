# xkai entry point
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/${
		""
	}F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
	std: "../plugins/std/main.roc",
}

import pf.OsStr
import pf.Stdout

import Builder
import Cli
import EmbeddedSources
import std.StdBundle

print_usage! = |_| {
	Stdout.line!(Cli.usage)?
	Ok({})
}

runtime_platform_name = Str.join_with(
	["F1JVZPYfWP71s8vk6tHcV1Qx", "1Ef6CZkwswGoCn8VHZmL"],
	"",
)

runtime_platform_url = Str.join_with(
	[
		"https://github.com/roc-lang/basic-cli/releases/download",
		"0.22.0",
		"${runtime_platform_name}.tar.zst",
	],
	"/",
)

stock_profile = {
	platform_url: runtime_platform_url,
	embedded_plugins: [StdBundle.plugin_source],
}

main! = |args| {
	display_args = args.drop_first(1).map(OsStr.display)
	match Cli.parse(display_args) {
		Cli.Command.Help => print_usage!({})
		Cli.Command.Version => {
			Stdout.line!("xkai version ${Cli.version}")?
			Ok({})
		}
		Cli.Command.Build(plugin_paths) =>
			Builder.build!(plugin_paths, EmbeddedSources.archive, stock_profile)
		Cli.Command.Unknown(unknown) => {
			Stdout.line!("Unknown command ${unknown}")?
			print_usage!({})
		}
	}
}
