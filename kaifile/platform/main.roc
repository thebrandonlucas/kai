## The Kaifile platform: apps are pure configuration. A `Kaifile.roc` provides
## `config`, a list of settings; the platform validates it and prints the
## Kaifile IR as an S-expression, which Kai turns into a working environment.
##
## ```roc
## app [config] { pf: platform "kaifile/platform/main.roc" }
##
## config = [
## 	Name("my-project"),
## 	Systems(["x86_64-linux", "aarch64-linux"]),
## 	Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
## 	Environment("dev", [Tools(["git", "python3", "stable#nodejs"])]),
## 	Shell("default", [Use("dev")]),
## 	Task("test", [Use("dev"), Run(["python3", "-m", "pytest"])]),
## 	Raw("nix", "shell:default", Attrs([("shellHook", Str("echo hi"))])),
## ]
## ```
##
## Unqualified tools use the "default" source, implicitly Auto; a consumer
## chooses the provider. "source#name" selects another declared source.
## Environments own tools and scoped overlays; shells and tasks use them.
## `Custom` and `Raw` take a `Val`, written with bare tags: `Str`, `Int`,
## `Bool`, `List` and `Attrs` (a list of (name, value) pairs).
##
## Every quoted value is checked as it compiles, through the `from_quote` of
## `Tool`, `System`, `FlakeRef`, `InputName`, `EnvName`, `TaskName`, or
## `WorkflowName`.
## Whole-config rules, including missing names and duplicate shells, are
## also checked at compile time by lowering `config` to the rendered IR.
platform ""
	requires {
		config : List(Config.Setting)
	}
	exposes [
		Config,
		EnvName,
		FlakeRef,
		InputName,
		System,
		TaskName,
		Tool,
		Val,
		WorkflowName,
	]
	packages {
		ir: "../ir/main.roc",
	}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_stderr_line": Host.stderr_line!,
		"roc_stdout_line": Host.stdout_line!,
	}
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Config
import Host
import Lower
import Tool
import FlakeRef
import EnvName
import InputName
import System
import TaskName
import Val
import WorkflowName
import ir.Ir

# Keep lowering at the top level so `roc check` validates the whole config.
# Kai's config fixtures (`zig build config-fixtures`) exercise this platform.
rendered : Str
rendered = or_crash(Lower.lower(config)).to_str()

or_crash : Try(Ir, Str) -> Ir
or_crash = |result|
	match result {
		Ok(ir) => ir
		Err(error) => crash "Invalid Kaifile.roc: ${error}"
	}

main_for_host! : List(Str) => I32
main_for_host! = |_args|
	match Host.stdout_line!(Str.drop_suffix(rendered, "\n")) {
		Ok({}) => 0
		Err(_) => 1
	}
