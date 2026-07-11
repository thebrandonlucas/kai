platform "kai-config"
	requires {
		config : List([
			Shell({ install : List(Str), run : Str }),
			MachineBuild({
				hostname : Str,
				system : Str,
				install : List(Str),
				ssh_keys : List(Str),
				state_version : Str,
				image : { format : Str },
			}),
		])
	}
	exposes [Kai, Stdout, Adapter]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_kai_shell": Host.kai_shell!,
		"roc_kai_config_shell": Host.kai_config_shell!,
		"roc_kai_machine_build": Host.kai_machine_build!,
		"roc_stdout_line": Host.stdout_line!,
	}
	targets: {
		inputs_dir: "targets/",
		x64mac: { inputs: ["libhost.a", app] },
		arm64mac: { inputs: ["libhost.a", app] },
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
		arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
		x64win: { inputs: ["host.lib", app] },
		arm64win: { inputs: ["host.lib", app] },
	}

import Kai
import Stdout
import Adapter
import Host

main_for_host! : List(Str) => I32
main_for_host! = |args| Kai.runConfig!(args, config)
