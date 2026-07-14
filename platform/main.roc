platform "kai"
	requires {
		main! : List(Str) => I32
	}
	exposes [Stdout]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
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

import Stdout
import Host

main_for_host! : List(Str) => I32
main_for_host! = |args| main!(args)
