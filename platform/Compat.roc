platform "kai-compat"
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
main_for_host! = |_args| {
	configured = Kai.with_backend(
		Kai.config(config),
		Command.Backend.Nix,
	)
	request : Kai.DispatchRequest
	request = {
		backend_candidate: Kai.BackendInput.Absent,
		command: "shell",
		args: [],
	}

	match Kai.dispatch(configured, module_changes, request) {
		Ok(result) =>
			match result.plan.files {
				[first, ..] =>
					match Host.stdout_line!(first.contents) {
						Ok({}) => 0
						Err(_) => 1
					}
				[] => {
					_ = Host.stderr_line!("kai: shell plan produced no files")
					1
				}
			}
		Err(error) => {
			_ = Host.stderr_line!(
				"kai: shell dispatch failed: ${Str.inspect(error)}",
			)
			1
		}
	}
}
