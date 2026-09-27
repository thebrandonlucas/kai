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
## std's settings, and the checks that run as Kaifile.roc compiles, are in
## plugins/std (`Config`, `Lower`).
platform ""
	requires {
		kaifile : Kaifile
	}
	exposes [
		Backend,
		Command,
		Implementation,
		Kaifile,
		Layout,
		LockJson,
		Plan,
		Plugin,
		Protocol,
		Sexpr,
		Value,
	]
	packages {
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
import Implementation
import Host
import Kaifile
import Layout
import LockJson
import Plan
import Plugin
import Protocol
import Sexpr
import Value

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
