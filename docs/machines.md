# Machines

The nixos plugin declares NixOS machines in Kaifile.roc, beside std's
environments, shells, tasks and builds. It is Nix only, and lives in
`plugins/nixos`.

```roc
app [kaifile] {
	pf: platform "<platform URL>",
	std: "<std URL>",
	nixos: "<nixos plugin URL>",
}

import pf.Kaifile
import std.Config
import std.Std
import nixos.Nixos

project : List(Config.Setting)
project = [
	Name("site"),
	Environment("ops", [Tools(["htop"])]),
]

kaifile = Kaifile.new([
	Std.plugin(project),
	Nixos.plugin(project, [
		Machine("web", [
			System("x86_64-linux"),
			StateVersion("25.05"),
			User("admin", [SshKeys(["ssh-ed25519 AAAA... admin@example"]), Groups(["wheel"])]),
			Ssh,
			Firewall([Tcp([80, 443])]),
			Use("ops"),
			Modules(["nixos/hardware.nix", "nixos/web.nix"]),
		]),
	]),
])
```

The plugin takes std's settings as well as its own, as the guix plugin does:
machines use the project's environments and its locked inputs. The nixos
plugin URL is the plugin bundled for your kai's release: `kai bundle-plugin
plugins/nixos` in a checkout of that release makes it, to host as
[plugin.md](plugin.md#publishing-a-plugin) describes.

## Settings

Every setting but `User` occurs at most once in a machine.

| Setting | Meaning |
|---|---|
| `System(system)` | Required. `x86_64-linux` or `aarch64-linux`, and one of the project's `Systems`. |
| `StateVersion(release)` | Required. NixOS's `system.stateVersion`, a release such as `"25.05"`: the release whose state formats the machine keeps. Set it once, when the machine is installed. |
| `HostName(name)` | `networking.hostName`. Optional (default: the machine's name). |
| `User(name, [...])` | An ordinary user, with `SshKeys([...])`, its authorized OpenSSH public keys, and `Groups([...])`, its supplementary groups such as `wheel`. `User("root", [SshKeys([...])])` authorizes keys for root, which takes no groups. |
| `Ssh` | OpenSSH, with key logins only: no passwords or keyboard-interactive logins, and root only with keys when root has some. It needs a `User` with `SshKeys`, and opens its port in the firewall. |
| `Firewall([Tcp([...]), Udp([...])])` | Ports the firewall opens, beside OpenSSH's. NixOS's firewall is on either way. |
| `TimeZone(zone)` | `time.timeZone`, such as `"Etc/UTC"`. Optional (default NixOS's, UTC). |
| `Use(environment)` | Puts a std environment's tools on the system's `PATH` (`environment.systemPackages`). The environment's variables stay in its shells and tasks. It cannot be one only the direct backend serves. |
| `Modules([...])` | NixOS module files, relative to the project and inside it, for everything else: services, disks, the boot loader, hardware. They receive the flake's `inputs` as a module argument, so a module can import another flake's module, such as `inputs.disko.nixosModules.disko` after `Input("disko", "github:nix-community/disko")` in std's settings. |

`kai check` refuses, as Kaifile.roc compiles, a machine name that is not a
letter followed by letters, digits, `-` or `_`; a missing or non-Linux
`System`, or one the project does not declare; a malformed `StateVersion`,
`HostName` or `TimeZone`; user and group names NixOS would refuse; a key that
is no OpenSSH public key; `Ssh` with no keys to log in with; port 0; an
unknown environment; and a module path that is absolute, uses `.` or `..`
segments, or is not a `.nix` file.

## How a machine reaches the flake

std generates `.kai/generated/nix/flake.nix` from the project's settings, with
the inputs `.kai/lock.json` pins. A machine command adds the project's
machines to that flake's outputs:

```nix
nixosConfigurations."web" = inputs."default".lib.nixosSystem {
  specialArgs = { inherit inputs; };
  modules = [
    { nixpkgs.hostPlatform = "x86_64-linux"; ... }   # the typed settings
    (/. + "/path/to/project/nixos/hardware.nix")
    (/. + "/path/to/project/nixos/web.nix")
  ];
};
```

The system comes from the project's `default` package source, so
`Packages("default", From(NixPackages("github:NixOS/nixpkgs/nixos-25.05")))`
picks the NixOS release, and `kai update` moves it with the rest of the
lock. Machines add no inputs, so the lock std's `kai update` writes serves
them.

A plugin adds outputs through std's public API, `Std.build_flake_output`,
described in [plugin.md](plugin.md#building-from-stds-flake).

## Commands

`kai machine build NAME` checks the machine's module files are in the
project, writes the flake and runs

```sh
nix build --no-link --print-out-paths --impure \
  path:.kai/generated/nix#nixosConfigurations.NAME.config.system.build.toplevel
```

printing the system's store path. `--impure` lets the flake read the module
files by their absolute paths; remote builders stay allowed, so a host with a
builder for the machine's system can build it. `kai --dry-run machine build
NAME` prints the plan, the generated flake included, instead.

A system needs a root file system and a boot loader, which come from a module
such as the `hardware-configuration.nix` that `nixos-generate-config` writes;
see [examples/machines](../examples/machines).

## Not yet

Switching a machine (`kai machine switch`, `rollback`, `generations`),
deploying to a remote host, services from the project's own builds, secrets,
disks and installation, and images come next; see
[#288](https://github.com/thebrandonlucas/kai/issues/288). Guix System is
not planned yet, though only `Modules` in the settings is Nix-specific.
