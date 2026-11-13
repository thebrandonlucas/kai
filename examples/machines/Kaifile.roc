# A NixOS machine beside the project's environments, from the machine plugin.
# Its typed settings cover the common core: the system, a user with an SSH
# key, OpenSSH with key logins only, the firewall and the time zone; Use puts
# the ops environment's tools on its PATH, and Modules adds plain NixOS
# module files, here the disk and boot loader a system needs. `kai machine
# build web` builds the system from the locked nixpkgs and prints its store
# path. Run on the machine itself, `kai machine switch web` also makes it
# the running system, and `--to admin@203.0.113.7` makes it that server's
# over SSH, as a Host("admin@...") setting would; the example only prints
# those plans.
app [kaifile] {
	machine: "../../plugins/machine/main.roc",
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import pf.Kaifile
import std.Config
import std.Std
import machine.Machine

project : List(Config.Setting)
project = [
	Name("machines"),
	Environment("ops", [Tools(["htop"])]),
	Shell("default", [Use("ops")]),
]

admin = "ssh-ed25519 "
	.concat("AAAAC3NzaC1lZDI1NTE5AAAAIMsUBl82wlnyo9fguo+DPfwmuCbdV4FBF/Qx8ZEUJz8X")

kaifile = Kaifile.new([
	Std.plugin(project),
	Machine.plugin(
		project,
		[
			Machine(
				"web",
				[
					System("x86_64-linux"),
					StateVersion("25.05"),
					TimeZone("Etc/UTC"),
					User("admin", [SshKeys([admin]), Groups(["wheel"])]),
					Ssh,
					Firewall([Tcp([80, 443])]),
					Use("ops"),
					Modules(["nixos/hardware.nix"]),
				],
			),
		],
	),
])
