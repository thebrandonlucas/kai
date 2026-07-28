platform "kai"
	requires {
		config : {
			name : Str,
			shell : { pkgs : List(Str) },
		}
	}
	exposes [Kai]
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
import Host

main_for_host! : List(Str) => I32
main_for_host! = |_args|
	match Kai.render(config) {
		Ok(source) =>
			match Host.stdout_line!(source) {
				Ok({}) => 0
				Err(_) => 1
			}

		Err(error) =>
			{
				_ = Host.stderr_line!("kai: ${Str.inspect(error)}")
				1
			}
		}
