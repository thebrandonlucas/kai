platform "kai-config"
	requires {
		config : {
			shell : {
				environment : Str,
				run : Str,
			},
			stdout : Str,
		}
	}
	exposes [Kai, Stdout, Adapter]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted { "roc_kai_shell": Host.kai_shell!, "roc_stdout_line": Host.stdout_line! }
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
main_for_host! = |_args| Kai.runConfig!(config)
