# Machines

The machine plugin declares machines in Kaifile.roc, beside std's
environments, shells, tasks and builds, and lives in `plugins/machine`. It
implements `kai machine` on the nix backend, where each machine is a NixOS
system; `Modules` is Nix's alone.

```roc
app [kaifile] {
	pf: platform "<platform URL>",
	std: "<std URL>",
	machine: "<machine plugin URL>",
}

import pf.Kaifile
import std.Config
import std.Std
import machine.Machine

project : List(Config.Setting)
project = [
	Name("site"),
	Input("disko", "github:nix-community/disko"),
	Environment("ops", [Tools(["htop"])]),
]

kaifile = Kaifile.new([
	Std.plugin(project),
	Machine.plugin(project, [
		Machine("web", [
			System("x86_64-linux"),
			StateVersion("25.05"),
			Host("admin@web.example.com"),
			User("admin", [SshKeys(["ssh-ed25519 AAAA... admin@example"]), Groups(["wheel"])]),
			Ssh,
			Firewall([Tcp([80, 443])]),
			Use("ops"),
			Disk(SingleDisk("/dev/sda")),
			Modules(["nixos/web.nix"]),
		]),
	]),
])
```

The plugin takes std's settings as well as its own, as the guix plugin does:
machines use the project's environments and its locked inputs. The machine
plugin URL is the plugin bundled for your kai's release: `kai bundle-plugin
plugins/machine` in a checkout of that release makes it, to host as
[plugin.md](plugin.md#publishing-a-plugin) describes.

## Settings

Every setting but `User` occurs at most once in a machine.

| Setting | Meaning |
|---|---|
| `System(system)` | Required. `x86_64-linux` or `aarch64-linux`, and one of the project's `Systems`. |
| `StateVersion(release)` | Required. NixOS's `system.stateVersion`, a release such as `"25.05"`: the release whose state formats the machine keeps. Set it once, when the machine is installed. |
| `HostName(name)` | `networking.hostName`. Optional (default: the machine's name). |
| `Host(target)` | The SSH target, `user@host` or `host`, that `switch`, `rollback` and `generations` act on; see [Remote machines](#remote-machines). Optional (default: the host kai runs on). |
| `User(name, [...])` | An ordinary user, with `SshKeys([...])`, its authorized OpenSSH public keys, and `Groups([...])`, its supplementary groups such as `wheel`. `User("root", [SshKeys([...])])` authorizes keys for root, which takes no groups. |
| `Ssh` | OpenSSH, with key logins only: no passwords or keyboard-interactive logins, and root only with keys when root has some. It needs a `User` with `SshKeys`, and opens its port in the firewall. |
| `Firewall([Tcp([...]), Udp([...])])` | Ports the firewall opens, beside OpenSSH's. NixOS's firewall is on either way. |
| `TimeZone(zone)` | `time.timeZone`, such as `"Etc/UTC"`. Optional (default NixOS's, UTC). |
| `Use(environment)` | Puts a std environment's tools on the system's `PATH` (`environment.systemPackages`). The environment's variables stay in its shells and tasks. It cannot be one only the direct backend serves. |
| `Disk(SingleDisk(device))` | The disk `kai machine install` partitions and the system boots from, the whole of `device`, an absolute `/dev/...` path such as `"/dev/sda"` or `"/dev/disk/by-id/..."`; see [Installing on a server](#installing-on-a-server). It needs `Input("disko", "github:nix-community/disko")` in std's settings. Optional (default: the file systems and boot loader come from `Modules`). |
| `Operators([...])` | The public keys of whoever may decrypt the machine's host key and secrets: age recipients (`age1...`) or `ssh-ed25519` and `ssh-rsa` public keys, at least one; see [Secrets](#secrets). Optional. |
| `Secrets([Secret(name, [...])])` | Files the system decrypts into `/run/secrets/NAME` as it activates, with `Owner(user)` (default `root`), `Group(group)` (default `root`) and `Mode("0400")`, an octal mode (default `"0400"`); see [Secrets](#secrets). They need `Operators` and `Input("agenix", "github:ryantm/agenix")` in std's settings. Optional. |
| `Services([...])` | Typed services the machine runs, each at most once: for now `Caddy([...])`, which serves sites over HTTPS; see [Services](#services). Optional. |
| `Modules([...])` | NixOS module files, relative to the project and inside it, for everything else: services, hardware, and the disks and boot loader when there is no `Disk`. They receive the flake's `inputs` as a module argument, so a module can import another flake's module, such as `inputs.disko.nixosModules.disko` after `Input("disko", "github:nix-community/disko")` in std's settings. |

`kai check` refuses, as Kaifile.roc compiles, a machine name that is not a
letter followed by letters, digits, `-` or `_`; a missing or non-Linux
`System`, or one the project does not declare; a malformed `StateVersion`,
`HostName` or `TimeZone`; a `Host` that is no SSH target; user and group
names NixOS would refuse; a key that
is no OpenSSH public key; `Ssh` with no keys to log in with; port 0; an
unknown environment; a `Disk` device that is no `/dev/...` path of letters,
digits and `._:+-`, or a `Disk` without the `disko` input; an operator
that is no age recipient, `ssh-ed25519` or `ssh-rsa` key, or empty
`Operators`; `Secrets` without `Operators` or without the `agenix` input,
a secret name that is not a letter followed by letters, digits, `-`, `_` or
`.`, a secret declared twice, an owner or group NixOS would refuse, or a
mode that is not three or four octal digits; a service given twice, and
what [Services](#services) lists for each; and a module path that is
absolute, uses `.` or `..` segments, or is not a `.nix` file.

## How a machine reaches the flake

std generates `.kai/generated/nix/flake.nix` from the project's settings, with
the inputs `.kai/lock.json` pins. A machine command adds the project's
machines to that flake's outputs:

```nix
nixosConfigurations."web" = inputs."default".lib.nixosSystem {
  specialArgs = { inherit inputs; };
  modules = [
    { nixpkgs.hostPlatform = "x86_64-linux"; ... }   # the typed settings
    (/. + "/path/to/project/nixos/web.nix")
  ];
};
```

The system comes from the project's `default` package source, so
`Packages("default", From(NixPackages("github:NixOS/nixpkgs/nixos-25.05")))`
picks the NixOS release, and `kai update` moves it with the rest of the
lock. Machines add no inputs of their own, so the lock std's `kai update`
writes serves them; a `Disk` uses the `disko` input std's settings declare,
and `Secrets` the `agenix` input, which `kai update` locks with the rest.

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

A system needs a root file system and a boot loader, which come from `Disk`
or from a module such as the `hardware-configuration.nix` that
`nixos-generate-config` writes; see [examples/machines](../examples/machines).

### Switching this host

Without `Host` or `--to`, `kai machine switch NAME`, `rollback NAME` and
`generations NAME` act on the host kai runs on, which must be the machine:
kai refuses a host of another system than the machine's `System` before
planning, and the plan's first step checks that `uname -n` is the machine's
`HostName`, failing otherwise. To change another host, run kai there, or
reach it over SSH as [Remote machines](#remote-machines) describes.

`kai machine switch NAME` builds the system as `build` does, leaving an
out-link at `.kai/machines/NAME`, then asks for confirmation and runs

```sh
sudo nix build --no-link --profile /nix/var/nix/profiles/system .kai/machines/NAME
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

which does what `nixos-rebuild switch` does once it has built: the system
becomes a new generation of the system profile (already built, it is only
recorded), is activated, restarting the services that changed, and is the
boot default. The build runs as you; only
these two commands run as root, through `sudo`. Switching the system that was
just built, rather than having `nixos-rebuild` evaluate the flake again,
means what kai printed is what runs.

`kai machine rollback NAME` asks, then switches back to the previous
generation:

```sh
sudo nix profile rollback --profile /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

`kai machine generations NAME` lists the system generations with
`nixos-rebuild list-generations`, which needs no root and, unlike `nix
profile history`, shows each generation's NixOS version and kernel.

Switch and rollback ask before changing the system, so they need a terminal
or `--yes`. A rollback changes only the host, not `.kai/lock.json`: the next
switch builds from the lock again. `kai --dry-run machine switch NAME` prints the whole plan, the host
check, the build and the confirmation included, and runs none of it.

### Remote machines

A machine with `Host("admin@web.example.com")` lives on that server, and
`kai machine switch`, `rollback` and `generations` act on it over SSH from
wherever kai runs. `--to TARGET` overrides `Host`, or gives a machine
without one a target, so a tool that has just created a server can pass its
address without editing the Kaifile:

```console
$ kai machine switch web
$ kai machine switch web --to admin@203.0.113.7
$ kai machine rollback web --to root@203.0.113.7
```

A target is `host` or `user@host`, where host is a name, such as an alias
from `~/.ssh/config`, or an IPv4 or IPv6 address. It takes no port: set one,
and any other SSH option, in `~/.ssh/config`. kai refuses a `Host` that is no
target as Kaifile.roc compiles, and a `--to` that is none before planning.
`kai machine build` always builds here: it ignores `Host` and refuses
`--to`.

`kai machine switch NAME` on a remote machine needs `nix` and `ssh` on
`PATH`. Its plan first checks over SSH that the target's `uname -m` is the
machine's architecture and that it runs NixOS (`/etc/NIXOS`); otherwise it
fails, saying to install NixOS with `kai machine install`. It then builds the
system here as a local switch does, leaving `.kai/machines/NAME`, asks for
confirmation naming the target, and runs

```sh
nix copy --substitute-on-destination --to ssh-ng://TARGET .kai/machines/NAME
ssh TARGET -- sudo nix --extra-experimental-features nix-command \
  build --no-link --profile /nix/var/nix/profiles/system STORE_PATH
ssh TARGET -- sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

where STORE_PATH is the system the out-link names, read as the step runs.
The target downloads what it can from its own substituters and receives the
rest. `kai machine rollback NAME` checks the target, asks, then runs

```sh
ssh TARGET -- sudo nix --extra-experimental-features nix-command \
  profile rollback --profile /nix/var/nix/profiles/system
ssh TARGET -- sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

and `kai machine generations NAME` checks it and runs `ssh TARGET --
nixos-rebuild list-generations`. When the target logs in as `root`, nothing
goes through `sudo`.

A user other than root needs two things on the target: `sudo` that asks for
no password, since the commands run without a terminal (for example
`security.sudo.wheelNeedsPassword = false;` in a module, with the user in
`wheel`), and the Nix daemon's trust, since only a trusted user may copy in a
system nobody signed. When `Host`'s user is a `User` of the machine, kai adds
it to `nix.settings.trusted-users`, beside root, so the first switch as root
or from the machine itself makes later ones as that user work. A `--to` user
must be root or already trusted.

### Installing on a server

`kai machine install NAME --to TARGET` erases a server's disk and installs
the machine there with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere).
The server can run any Linux, as long as `TARGET` logs in as root over SSH,
or as a user with password-less `sudo`, and it has about 1 GB of RAM:
nixos-anywhere boots a NixOS installer into memory with kexec, partitions
the disk with [disko](https://github.com/nix-community/disko), copies the
system and reboots into it. kexec fails in containers (LXC, OpenVZ) and on
some ARM and Secure Boot hosts.

kai needs only that SSH target. Creating the server, adding your SSH key to
it, DNS, snapshots and destroying it are the provider's, through its own
tools or a provider plugin, which hand kai the address:

```text
a provider tool or a person          kai
---------------------------          ----------------------------------------
create server, add SSH key   --->    kai machine install web --to root@203.0.113.7
DNS, snapshots, billing              kai machine switch web
destroy server
```

What a provider needs of the machine itself, such as DigitalOcean's metadata
networking or a disk named `/dev/vda` rather than `/dev/sda`, is a NixOS
module file the Kaifile includes with `Modules([...])`, not a kai setting.

A machine to install needs:

- `Disk(SingleDisk(device))`, the disk to erase. It partitions the disk as
  GPT with a 1 MiB BIOS boot partition, a 512 MiB EFI system partition
  mounted at `/boot` and an ext4 root filling the rest, and boots it with
  GRUB on both BIOS and UEFI, which is nixos-anywhere's own example layout.
  `Modules` must then not define the root file system or the boot loader.
- `Input("disko", "github:nix-community/disko")` in std's settings, which
  the Disk's module comes from, locked by `kai update`; kai refuses a Disk
  without it as Kaifile.roc compiles. std's `Follows` only makes an
  `Overlay`'s inputs follow a package source, so disko's own nixpkgs is
  locked apart from the project's; the system, disko's module included,
  still builds from the project's `default` source.
- `Ssh` and a `User` with `SshKeys`, since those keys are how you reach the
  server once it runs the machine. Logging in as root afterwards needs
  `User("root", [SshKeys([...])])`; a user other than root needs
  password-less `sudo` for later switches, as above.

`--to` is required and `Host` is never used instead: an install erases the
disk, and its target is usually a fresh server's root address, not where
the machine will be reached afterwards. kai refuses an install without
`--to`, of a machine without `Disk`, or without `Ssh`, before planning.

The plan needs `nix` and `ssh` on `PATH`. It writes the flake and builds the
system as `kai machine build` does, so a system that fails to build fails
before anything is erased, then asks for confirmation naming the target and
the disk it will erase, and runs nixos-anywhere from the project's locked
nixpkgs, with no separate install:

```sh
nix run --inputs-from path:.kai/generated/nix default#nixos-anywhere -- \
  --flake path:.kai/generated/nix#NAME --target-host TARGET
```

It runs with `pure-eval = false` added to any `NIX_CONFIG` you have, which lets nixos-anywhere's own `nix build` read the machine's
module files by their absolute paths, as `--impure` does for `kai machine
build`. The install asks before erasing anything, so it needs a terminal or
`--yes`; `kai --dry-run machine install NAME --to TARGET` prints the whole
plan and runs none of it.

A machine with `Operators` installs inside one script under age and
ssh-keygen from the locked nixpkgs, as [Secrets](#secrets) describes: it
decrypts or makes the machine's SSH host key in a private temporary
directory and passes nixos-anywhere `--extra-files` with it, so the
command needs `--identity` when your key is not `~/.ssh/id_ed25519`.

Afterwards the server runs the machine, and `kai machine switch NAME --to
USER@ADDRESS`, or `Host`, changes it as [Remote machines](#remote-machines)
describes.

## Secrets

A machine's secrets, such as an API key a service reads, are encrypted
files in the project, decrypted on the machine as it activates by
[agenix](https://github.com/ryantm/agenix):

```roc
project = [
	Name("site"),
	Input("disko", "github:nix-community/disko"),
	Input("agenix", "github:ryantm/agenix"),
]

Machine("web", [
	...,
	Operators(["age1...", "ssh-ed25519 AAAA... admin@example"]),
	Secrets([Secret("app-key", [Owner("app"), Mode("0400")])]),
])
```

`Operators` are the public keys of the people, or the CI, who may read and
change the secrets: age recipients or OpenSSH `ssh-ed25519` and `ssh-rsa`
keys. Three kinds of file live under `secrets/` in the project:

| File | Holds |
|---|---|
| `secrets/hosts/NAME.pub` | The machine's SSH host public key, in plaintext. |
| `secrets/hosts/NAME.age` | Its private host key, encrypted to the Operators. |
| `secrets/NAME/SECRET.age` | Each secret, encrypted to the Operators and the host key. |

```console
$ printf %s "$API_KEY" | kai secret set web app-key
$ kai secret rekey web
$ kai secret rekey web --identity ~/.ssh/admin_ed25519
```

`kai secret set MACHINE SECRET` encrypts what it reads on stdin, refusing a
machine or secret the Kaifile does not declare. `kai secret rekey MACHINE`
decrypts each of `secrets/MACHINE/*.age` and encrypts it again to the
current Operators and host key, and the host key again to the Operators:
run it after changing `Operators`. Each writes std's flake first and runs
age and ssh-keygen from the project's locked nixpkgs, so they need only
`nix` on `PATH`:

```sh
nix shell --inputs-from path:.kai/generated/nix default#age default#openssh \
  --command sh -c SCRIPT sh ...
```

Whatever decrypts, `rekey` and `kai machine install`, uses `--identity
PATH` (`-i`), an age identity file or an SSH private key matching one of the
Operators, by default `~/.ssh/id_ed25519`.

On the machine, each secret is `age.secrets."SECRET"`, decrypted with the
host key `/etc/ssh/ssh_host_ed25519_key` into `/run/secrets/SECRET`, owned
by its `Owner` and `Group` with its `Mode`. `kai machine build`, `switch`
and `install` check that every declared secret's file exists before
building, and fail naming `kai secret set` for the missing one.

### The host key comes first

A secret encrypted to a machine's host key cannot be written until that key
exists, so kai makes it. `kai machine install` with `Operators` generates an
ed25519 host key here, stores it as `secrets/hosts/NAME.age` and `.pub`,
encrypts any secrets already in `secrets/NAME/` again to it, and places it
at `/etc/ssh/ssh_host_ed25519_key` with nixos-anywhere's `--extra-files`,
so the machine boots able to decrypt its secrets. Installing again reuses
the stored key. Before the first install, `kai secret set` encrypts to the
Operators only and says so; the install then adds the host key. For a
machine installed some other way, copy its
`/etc/ssh/ssh_host_ed25519_key.pub` to `secrets/hosts/NAME.pub` and run
`kai secret rekey NAME`.

### What is safe to commit

The Kaifile and everything under `secrets/` are safe to commit: the only
plaintext file there is the host's public key. Plaintext secrets and the
private host key exist only in the temporary directory of the step that
needs them, which it makes private and removes however it ends; `kai
secret set` pipes stdin straight to age. Nothing in plaintext enters the
Nix store, `.kai/` or the project: the store holds only the encrypted
files, and agenix decrypts them on the machine into `/run/secrets`, which
is in memory. Anyone holding an Operator's private key, or the machine's
host key, can read the secrets. Losing every Operator's private key loses
the secrets and the stored host key for good, so keep more than one
Operator, or a backup of one.

kai uses agenix rather than sops-nix because one encrypted file per secret
matches one `Secret(name)` each, needs no YAML or JSON document, and keeps
`kai secret set` to one value at a time; sops-nix's several values per file
is no advantage when each secret is declared on its own.

## Services

`Services([...])` declares the typed services a machine runs, each at most
once. There is one so far, [Caddy](https://caddyserver.com), a web server
that gets and renews its sites' HTTPS certificates itself:

```roc
Machine("web", [
	...,
	Services([
		Caddy([
			Email("admin@example.com"),
			Site("example.com", ReverseProxy("localhost:8080")),
			Site("files.example.com", Files("/srv/files")),
		]),
	]),
])
```

On NixOS it renders

```nix
networking.firewall.allowedTCPPorts = [ 80 443 ];
networking.firewall.allowedUDPPorts = [ 443 ];
services.caddy.enable = true;
services.caddy.email = "admin@example.com";
services.caddy.virtualHosts."example.com".extraConfig = "reverse_proxy localhost:8080";
services.caddy.virtualHosts."files.example.com".extraConfig = "root * /srv/files\nfile_server";
```

| Setting | Meaning |
|---|---|
| `Site(domain, ReverseProxy(upstream))` | Serves `domain` over HTTPS, passing requests to `upstream`: `host:port`, such as `"localhost:8080"`, `[ipv6]:port` or `unix//path` for a Unix socket. |
| `Site(domain, Files(path))` | Serves `domain` over HTTPS from the files in the absolute directory `path`. |
| `Email(address)` | The address Caddy gives the certificate authority for its account, which warns of certificates about to expire. Optional, at most once. |

A domain is a lowercase DNS name with no scheme, port or path, such as
`"example.com"`. Wildcards such as `"*.example.com"` are refused: their
certificate needs a DNS challenge, with the DNS provider's credentials,
which kai does not set up yet, so give each name its own `Site`. A
domain's DNS records must point at the machine before Caddy can get a
certificate for it.

Caddy needs TCP port 80, for HTTP, which it redirects to HTTPS and where
it answers the certificate authority's challenge, and 443, for HTTPS, and
UDP port 443 for HTTP/3. kai adds them to the ports `Firewall` opens,
once each, so a machine with `Firewall([Tcp([80, 443, 8443])])` and Caddy
opens those three TCP ports and UDP 443.

`kai check` refuses Caddy without a `Site`, a domain served twice, an
`Email` given twice, and a value that is not plainly what it claims: a
domain that is no lowercase DNS name, an upstream that is not one of the
forms above or holds whitespace, a `Files` path that is not absolute or
holds anything but letters, digits and `/._-+@,`, and an email that is not
one `local@domain` address. Each value lands in a Caddyfile, so kai checks
it rather than escaping it, and none can add a directive of its own.

### How services work

Each typed service is a module of the machine plugin's `services` package,
such as `plugins/machine/services/Caddy.roc`: its settings, their checks
and the backend-neutral model they fold into. The machine's model holds
that model, and each backend renders it; on nix, `NixosBackend.roc` renders
Caddy as `services.caddy`. A second service is another module there, a tag
in `Services`, and a renderer in each backend.

What a service needs of the machine it gets through the machine's model:
Caddy adds its ports to the firewall's. A service that needs a user would
add one the same way, and one that needs a secret would name a declared
`Secret`, which it reads at `/run/secrets/NAME`. Services refer to each
other by what they listen on: a `Site` proxies to `localhost:8080` where
another service, or a `Modules` file, serves that port.

Everything without a typed service stays in `Modules`, and an untyped
`Options([...])`, which `kai check` validates against the options of the
locked nixpkgs, is planned next; typed services stay the small, canonical
layer for the common cases.

## Not yet

`Options([...])`, more typed services such as Postgres, backups and the
project's own builds, `kai machine image` for providers that boot from
images, test machines with microvm, and `kai machine gc` come next; see
[#463](https://github.com/thebrandonlucas/kai/issues/463). Guix System is
not planned yet, though only `Modules` in the settings is Nix-specific.
