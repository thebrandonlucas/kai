platform "kai"
	requires {
		config : {
			name : Str,
			shell : { pkgs : List(Str) },
		},
		module_changes : List(
			[
				Add(
					{
						command : Str,
						contract : Str,
						id : Str,
						backends : List([Nix]),
						handler : {
							project : Str,
							backend : [Nix],
							args : List(Str),
						} -> Try(
							{
								files : List({ path : Str, contents : Str }),
								argv : List(Str),
							},
							[PlanningFailed(Str)],
						),
					},
				),
				Replace(
					{
						command : Str,
						contract : Str,
						id : Str,
						backends : List([Nix]),
						handler : {
							project : Str,
							backend : [Nix],
							args : List(Str),
						} -> Try(
							{
								files : List({ path : Str, contents : Str }),
								argv : List(Str),
							},
							[PlanningFailed(Str)],
						),
					},
				),
			],
		)
	}
	exposes [Kai, Command]
	packages {
		blueprint: "blueprint/package.roc",
	}
	provides {
		"roc_main": main_for_host!,
	}
	hosted {
		"roc_stdout_line": Host.stdout_line!,
		"roc_stderr_line": Host.stderr_line!,
	}
	targets: {
		inputs_dir: "targets/",
		x64mac: { inputs: ["libhost.a", app] },
		arm64mac: { inputs: ["libhost.a", app] },
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Kai
import Command
import Host

main_for_host! : List(Str) => I32
main_for_host! = |_args|
	match Kai.registry(Kai.config(config), module_changes) {
		Ok(_registry) => 0
		Err(error) => {
			_ = Host.stderr_line!(
				"kai: invalid module composition: ${Str.inspect(error)}",
			)
			1
		}
	}
