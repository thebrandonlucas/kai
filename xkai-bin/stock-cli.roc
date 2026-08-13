app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "./package.roc",
	std: "../plugins/main.roc",
}

import Executor
import kai.Plugin as PluginApi
import std.StdPlugin

registry = [StdPlugin.plugin]

main! = |args| Executor.run!(args, registry)

# -- TESTS --

plans_shell_packages = |source, expected|
	match PluginApi.plan_registry(registry, source, ["shell"], LINUX, X64) {
		Ok(plan) => plan.requested_packages == expected
		Err(_) => Bool.False
	}

comment_cases = [
	{
		expected: ["cow#say", "fortune"],
		source: "# before host {\non # between header words\nlinux {\n  # inside host }\n  shell # between header and brace\n  {\n    # inside body }\n    packages: [\n      \"cow#say\", # after item\n      # before item\n      \"fortune\"\n    ] # after field\n  }\n}\n# after host }",
	},
	{ expected: ["cow#say"], source: "shell { packages: [\"cow#say\"] }" },
	{ expected: [], source: "shell { packages: [] } # comment at end of file" },
]

expect List.all(comment_cases, |case| plans_shell_packages(case.source, case.expected))
