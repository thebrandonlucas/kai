# Plugins lower typed config into this platform's stable ModuleConfig shape.
platform "kai"
	requires {
		config : _
	}
	exposes [Kai]
	packages {
		kai: "../xkai-bin/package.roc",
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
		arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Kai
import Host

main_for_host! : List(Str) => I32
main_for_host! = |args|
# NOTE: We do type inference `config: _` above because otherwise
# we'd have to manually keep the type in sync with
# Kai.ModuleConfig, but we can't use that type there before its
# been imported.

# Kai.render call lower down ensures the type is constrained.
	match Kai.render(config, args) {
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
