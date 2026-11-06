# A NixOS machine beside the project's environments, from the nixos plugin.
# Its typed settings cover the common core: the system, a user with an SSH
# key, OpenSSH with key logins only, the firewall and the time zone; Use puts
# the ops environment's tools on its PATH, and Modules adds plain NixOS
# module files, here the disk and boot loader a system needs. `kai machine
# build web` builds the system from the locked nixpkgs and prints its store
# path.
app [kaifile] {
	nixos: "../../plugins/nixos/main.roc",
	pf: platform "../../platform/main.roc",
	std: "../../plugins/std/main.roc",
}

import pf.Kaifile
import std.Config
import std.Std
import nixos.Nixos

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
	Nixos.plugin(
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
