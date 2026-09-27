## The Kaifile platform: apps are pure configuration. A `Kaifile.roc` provides
## `kaifile`, its plugins; the platform validates them and prints the Kaifile
## IR as an S-expression, which Kai turns into a working environment. The std
## plugin takes a list of settings:
##
## ```roc
## app [kaifile] {
## 	pf: platform "kaifile/platform/main.roc",
## 	std: "plugins/std/main.roc",
## }
##
## import std.Std
##
## kaifile = Std.kaifile([
## 	Name("my-project"),
## 	Systems(["x86_64-linux", "aarch64-linux"]),
## 	Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
## 	Environment("dev", [Tools(["git", "python3", "stable#nodejs"])]),
## 	Shell("default", [Use("dev")]),
## 	Task("test", [Use("dev"), Run(["python3", "-m", "pytest"])]),
## 	Raw("nix", "shell:default", Attrs([("shellHook", Str("echo hi"))])),
## ])
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
## also checked at compile time, when std lowers its settings to the IR.
platform ""
	requires {
		kaifile : Kaifile
	}
	exposes [
		Backend,
		Command,
		Config,
		EnvName,
		FlakeRef,
		Implementation,
		InputName,
		Kaifile,
		LockJson,
		Lower,
		Plan,
		Plugin,
		Protocol,
		System,
		TaskName,
		Tool,
		Val,
		WorkflowName,
	]
	packages {
		ir: "../ir/main.roc",
		weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/${
			""
		}0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_stdin_read_to_end": Host.stdin_read_to_end!,
		"roc_stderr_line": Host.stderr_line!,
		"roc_stdout_line": Host.stdout_line!,
	}
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
		arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Answer
import Argv
import Backend
import Command
import Config
import Implementation
import Host
import Lower
import Tool
import FlakeRef
import EnvName
import InputName
import Kaifile
import LockJson
import Plan
import Plugin
import Protocol
import System
import TaskName
import Val
import WorkflowName

# Keep validation at the top level so `roc check` validates the whole Kaifile.
# Kai's config fixtures (`zig build config-fixtures`) exercise this platform.
rendered : Str
rendered = or_crash(Kaifile.validate(kaifile))

or_crash : Try(Str, Str) -> Str
or_crash = |result|
	match result {
		Ok(text) => text
		Err(error) => crash "Invalid Kaifile.roc: ${error}"
	}

# Without a request on stdin, the Kaifile IR, as before kai sent requests.
main_for_host! : List(Str) => I32
main_for_host! = |_args| {
	request = Host.stdin_read_to_end!() ?? ""
	answer = if request.is_empty() {
		Str.drop_suffix(rendered, "\n")
	} else {
		_ = rendered
		Answer.respond(kaifile, request)
	}
	match Host.stdout_line!(answer) {
		Ok({}) => 0
		Err(_) => 1
	}
}
