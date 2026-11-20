# The machine and secret commands on the nix backend: each machine is a
# NixOS system in std's generated flake, built from it, switched to here or
# over SSH, installed on a server with nixos-anywhere, and given secrets
# that agenix decrypts.
import pf.Command
import pf.Implementation
import pf.Plan
import std.Config
import std.Std
import services.Caddy
import MachineModel exposing [Machine]

## Each machine is `lib.nixosSystem` of the "default" package source, with
## one module holding its typed settings, then its own module files by
## absolute path and its inputs' module files by store path. Modules
## receive the flake's `inputs` as an argument.
NixosBackend :: [].{

	Project : List(Config.Setting)

	Planned : Try(Plan, Plan.Failure)

	Context : Implementation.Context

	## What a build of the flake builds: its attribute, the name kai prints
	## its store path by, its description, and its out-link ("" for none).
	Built : { attribute : Str, name : Str, description : Str, out_link : Str }

	implementation : Project, List(Machine) -> Implementation
	implementation = |project, declared|
		Implementation.{
			command: "machine",
			backend: On("nix"),
			fit: |args| MachineModel.requested(declared, args).map_ok(|_| {}),
			plan: |ctx| {
				m = MachineModel.requested(declared, ctx.args).map_err(Plan.fail)?
				machines = NixosBackend.with_instance(declared, m)
				action = Command.name(ctx.args, "action")
				destination = MachineModel.destination(m, ctx.args).map_err(Plan.fail)?
				if action == "build" {
					NixosBackend.build(project, machines, m, ctx, "")
				} else if action == "install" {
					MachineModel.installable(m).map_err(Plan.fail)?
					match destination {
						Remote(target) => NixosBackend.install(project, machines, m, ctx, target)
						Here => Err(Plan.fail("kai machine install needs --to"))
					}
				} else {
					# A remote machine with Operators may have a host key: its
					# public key is read first, so the plan reports a phase later.
					keyed = destination != Here and !m.operators.is_empty()
					reporting = if (keyed) 2 else 1
					match destination {
						_ if ctx.phase >= reporting =>
							NixosBackend.report(m, ctx, action, destination)
						Here => NixosBackend.on_host(project, machines, m, ctx, action)
						Remote(target) if keyed and ctx.phase == 0 =>
							NixosBackend.read_host_key(m, ctx, action, target)
						Remote(target) =>
							NixosBackend.on_remote(project, machines, m, ctx, action, target)
					}
				}
			},
		}

	## The machines the flake defines: the declared ones, and `m` too when
	## it is an instance, as `nixosConfigurations.<instance>`, which reads
	## the instance's hardware facts and secrets. Only the command line
	## names an instance, so the command naming one renders it.
	with_instance : List(Machine), Machine -> List(Machine)
	with_instance = |declared, m|
		if (m.instance == m.name) declared else declared.append(m)

	## What only Nix can honour that is wrong with machine `m`.
	problems : Machine -> List(Str)
	problems = |m| {
		outside = |file| !NixosBackend.valid_module_path(file.path)
		not_in_input = |{ input, path }|
			"module ${path} is no .nix file inside input ${input}"
		m.modules
			.drop_if(NixosBackend.valid_module_path)
			.map(|path| "module ${path} is no .nix file inside the project")
			.concat(
				m.input_modules
					.keep_if(outside)
					.map(not_in_input),
			)
	}

	## What std's update locks for `machines`: the "default" package source
	## they are built from, and disko and nixos-images for a Disk and agenix
	## for Secrets, each with its nixpkgs following that source. agenix's
	## darwin and home-manager inputs follow its nixpkgs, and so that source
	## too. Both of nixos-images' nixpkgs follow it, so install boots an
	## installer of the same nixpkgs as the disko it runs.
	lock_requests : List(Machine) -> List(Implementation.LockRequest)
	lock_requests = |machines| {
		following = [Follows("nixpkgs", "default")]
		disko = Input("disko", "github:nix-community/disko", following)
		agenix = Input("agenix", "github:ryantm/agenix", following)
		images = Input(
			"nixos-images",
			"github:nix-community/nixos-images",
			[Follows("nixos-unstable", "default"), Follows("nixos-stable", "default")],
		)
		when = |present, requests| if (present) requests else []
		when(!machines.is_empty(), [Source("default")])
			.concat(when(machines.any(|m| m.disk != NoDisk), [disko, images]))
			.concat(when(machines.any(|m| !m.secrets.is_empty()), [agenix]))
	}

	## A relative path to a .nix file that stays inside the project, or the
	## input.
	valid_module_path : Str -> Bool
	valid_module_path = |path|
		path.ends_with(".nix")
			and path.split_on("/").all(|s| !s.is_empty() and s != "." and s != "..")

	## NixOS's system profile, whose generations are the host's systems.
	profile = "/nix/var/nix/profiles/system"

	## Switching, rolling back and listing act on this host, which must be
	## the machine: its System now, its HostName as the plan runs. Only the
	## profile and the activation run as root, through sudo, which asks for
	## a password on the terminal itself, so they stay quiet. Each records
	## the generations for `report`.
	on_host : Project, List(Machine), Machine, Context, Str -> Planned
	on_host = |project, machines, m, ctx, action| {
		if ctx.host.system != m.system {
			return Err(
				Plan.fail(
					"${MachineModel.called(m)} is ${m.system}, but this host is "
						.concat("${ctx.host.system}: ")
						.concat(NixosBackend.local_only(action, m)),
				),
			)
		}
		description = "machine ${action} ${MachineModel.named(m)}"
		system_profile = NixosBackend.profile
		check = NixosBackend.host_check(action, m)
		here = NixosBackend.run("${description}: host check", Quiet, check)
		sudo = |argv| NixosBackend.run(description, Quiet, ["sudo"].concat(argv))
		file = NixosBackend.generations_file(ctx)
		recording = |script, as_root| {
			argv = ["sh", "-c", script, "sh", system_profile].concat(as_root)
			NixosBackend.run(description, Quiet, NixosBackend.recorded(file, argv))
		}
		activate = recording(NixosBackend.activation, ["sudo"])
		restarting = "restarting changed services and booting it by default?"
		steps = match action {
			"switch" => {
				link = "${ctx.layout.workspace}/machines/${m.instance}"
				built = NixosBackend.build(project, machines, m, ctx, link)?
				called = MachineModel.called(m)
				prompt = "Switch this host to ${called}, ${restarting}"
				set = sudo(["nix", "build", "--no-link", "--profile", system_profile, link])
				activating = Note("activating ${called}'s system on this host")
				[here]
					.concat(built.steps)
					.concat([Confirm(prompt), activating, set, activate])
			}
			"rollback" => {
				prompt = "Switch this host back to its previous system, ${restarting}"
				# Steps the profile's link back a generation, as `nix-env
				# --rollback` does: it needs no `nix profile` manifest.
				back = sudo(["nix", "profile", "rollback", "--profile", system_profile])
				activating = Note("activating this host's previous system")
				[here, Confirm(prompt), activating, back, activate]
			}
			_ => [here, recording(NixosBackend.listing, [])]
		}
		Ok(Plan.{ steps, next: Observe([file]) })
	}

	## Switching, rolling back and listing act on `target` over SSH, which
	## must run NixOS on the machine's architecture. The system is built
	## here and copied there; only the profile and the activation run as
	## root there, through sudo unless the target logs in as root. Each
	## records the generations for `report`. A switch arms a timer there
	## that rolls the target back unless a new SSH connection stops it once
	## the system is active, so a system that fails to activate, or breaks
	## SSH, undoes itself. Every SSH connection goes to the target's port,
	## and trusts the machine's host key when `read_host_key` found it, else
	## the operator's known hosts.
	on_remote : Project, List(Machine), Machine, Context, Str, Str -> Planned
	on_remote = |project, machines, m, ctx, action, target| {
		description = "machine ${action} ${MachineModel.named(m)} on ${target}"
		system_profile = NixosBackend.profile
		programs = if (action == "switch") ["nix", "ssh"] else ["ssh"]
		tools = [ExpectPrograms({ description, programs })]
		trust = NixosBackend.trusted_host_key(m, ctx)?
		check = NixosBackend.remote_check(m, target, trust.options)
		there = NixosBackend.run("${description}: host check", Quiet, check)
		# The known hosts file is written before the first connection.
		first = tools.concat(trust.steps).append(there)
		root = MachineModel.target_user(target) == "root"
		as_root = |argv| if (root) argv else ["sudo"].concat(argv)
		# The remote nix may not enable `nix profile` and `nix build`.
		nix = ["nix", "--extra-experimental-features", "nix-command"]
		reach = NixosBackend.ssh_target(target)
		options = reach.options.concat(trust.options)
		# ssh joins the words for the remote shell, so each is quoted for it.
		remote = |argv|
			["ssh"]
				.concat(options)
				.concat([reach.destination, "--"])
				.concat(argv.map(NixosBackend.shell_quote))
		quiet = |argv| NixosBackend.run(description, Quiet, argv)
		file = NixosBackend.generations_file(ctx)
		on_profile = |script|
			remote(["sh", "-c", script, "sh", system_profile].concat(as_root([])))
		recorded = |script| NixosBackend.recorded(file, on_profile(script))
		activate = quiet(recorded(NixosBackend.activation))
		restarting = "restarting changed services and booting it by default?"
		steps = match action {
			"switch" => {
				link = "${ctx.layout.workspace}/machines/${m.instance}"
				built = NixosBackend.build(project, machines, m, ctx, link)?
				prompt = "Switch ${target} to ${MachineModel.called(m)}, ${restarting}"
				# The URL holds no port: NIX_SSHOPTS passes it to ssh.
				store = "ssh-ng://${reach.destination}"
				# A system built here is unsigned; the target still refuses it from
				# a user it does not trust.
				copy = ["nix", "copy", "--no-check-sigs", "--substitute-on-destination"]
					.concat(["--to", store, link])
				set_profile = ["build", "--no-link", "--profile", system_profile]
				set_command = as_root(nix.concat(set_profile))
				set = NixosBackend.remote_profile(link, target, set_command, trust.options)
				# Until kai reaches the target again once it is active, a timer
				# there stands ready to roll it back.
				rolls_back = "${target} rolls back to its previous system in 5 minutes"
				guarded = |why, argv|
					NixosBackend.run("${description}: ${why}, so ${rolls_back}", Quiet, argv)
				disarm = remote(as_root(["systemctl", "stop", "kai-rollback.timer"]))
				reaching = "which rolls back unless kai reaches it again"
				first
					.concat(built.steps)
					.concat([
						Confirm(prompt),
						Note("copying ${MachineModel.called(m)}'s system to ${target}"),
						quiet(NixosBackend.with_ssh_options(options, copy)),
						Note("activating it on ${target}, ${reaching}"),
						quiet(on_profile(NixosBackend.arming)),
						quiet(set),
						guarded("its activation failed", recorded(NixosBackend.activation)),
						guarded("kai cannot reach it again", disarm),
					])
			}
			"rollback" => {
				prompt = "Switch ${target} back to its previous system, ${restarting}"
				rollback = ["profile", "rollback", "--profile", system_profile]
				back = quiet(remote(as_root(nix.concat(rollback))))
				activating = Note("activating the previous system on ${target}")
				first.concat([Confirm(prompt), activating, back, activate])
			}
			_ => first.append(quiet(recorded(NixosBackend.listing)))
		}
		Ok(Plan.{ steps, next: Observe([file]) })
	}

	## Where a remote action copies machine `m`'s host public key,
	## secrets/hosts/INSTANCE.pub, for its continuation to read.
	host_key_copy : Context -> Str
	host_key_copy = |ctx| "${ctx.layout.generated_root}/machine/host-key.pub"

	## The known hosts file holding only a remote machine's host key.
	known_hosts_file : Context -> Str
	known_hosts_file = |ctx| "${ctx.layout.generated_root}/machine/known_hosts"

	## The first phase of a remote action on machine `m`, which has
	## Operators: a plugin reads only generated files, so this copies its
	## host public key, when kai made or was given one, for
	## `trusted_host_key` to read, removing a stale copy first.
	read_host_key : Machine, Context, Str, Str -> Planned
	read_host_key = |m, ctx, action, target| {
		script =
			\\rm -f "$2" || exit
			\\[ -e "$1" ] || exit 0
			\\mkdir -p "$(dirname "$2")" || exit
			\\exec cp "$1" "$2"
		public_key = "${ctx.layout.project_root}/secrets/hosts/${m.instance}.pub"
		copy = NixosBackend.host_key_copy(ctx)
		named = MachineModel.named(m)
		description = "machine ${action} ${named} on ${target}: host key"
		argv = ["sh", "-c", script, "sh", public_key, copy]
		steps = [NixosBackend.run(description, Quiet, argv)]
		Ok(Plan.{ steps, next: Observe([copy]) })
	}

	## The ssh options trusting exactly machine `m`'s host key, as
	## `read_host_key` copied it, and the step writing the known hosts file
	## they name: the key under the instance's name, by which ssh looks it up
	## in that file alone, whatever address or ~/.ssh/config alias the
	## target is. Without the key there are none, and ssh checks the
	## operator's known hosts. ssh splits the file's name at spaces, and Nix
	## NIX_SSHOPTS too, so its path must hold none.
	trusted_host_key : Machine, Context -> Try(Trust, Plan.Failure)
	trusted_host_key = |m, ctx| {
		copy = NixosBackend.host_key_copy(ctx)
		text = match ctx.observed.find_first(|o| o.path == copy) {
			Ok({ contents: Text(contents), .. }) => contents
			_ => return Ok({ steps: [], options: [] })
		}
		key = text.split_on("\n").first().map_ok(Str.trim) ?? ""
		known = NixosBackend.known_hosts_file(ctx)
		plain = |b| !" \t\n\r%\"'\\".to_utf8().contains(b)
		if key.is_empty() {
			Err(Plan.fail("secrets/hosts/${m.instance}.pub holds no public key"))
		} else if !known.to_utf8().all(plain) {
			Err(
				Plan.fail(
					"ssh cannot name the known hosts file ${known}: its path "
						.concat("holds a space, a quote or %"),
				),
			)
		} else {
			file = { path: known, contents: "${m.instance} ${key}\n" }
			options = ["-o", "UserKnownHostsFile=${known}"]
				.concat(["-o", "GlobalKnownHostsFile=/dev/null"])
				.concat(["-o", "StrictHostKeyChecking=yes"])
				.concat(["-o", "HostKeyAlias=${m.instance}"])
			Ok({ steps: [Write([file])], options })
		}
	}

	## ssh options, and the steps to take before they hold.
	Trust : { steps : List(Plan.Step), options : List(Str) }

	## `argv`, a nix command, with ssh `options` in NIX_SSHOPTS before the
	## operator's own, so that ssh takes them first; `argv` alone without.
	with_ssh_options : List(Str), List(Str) -> List(Str)
	with_ssh_options = |options, argv|
		if options.is_empty() {
			argv
		} else {
			script =
				\\options=$1
				\\shift
				\\[ -z "$NIX_SSHOPTS" ] || options="$options $NIX_SSHOPTS"
				\\export NIX_SSHOPTS="$options"
				\\exec "$@"
			["sh", "-c", script, "sh", Str.join_with(options, " ")].concat(argv)
		}

	## Where a switch, rollback or listing records the system profile's
	## generations for `report`: the link the profile points at, such as
	## system-43-link, then, when listing, each generation's link and the
	## time it was made, oldest first.
	generations_file : Context -> Str
	generations_file = |ctx| "${ctx.layout.generated_root}/machine/generations"

	## Arms a timer, as root through the words after the system profile
	## `$1`, that switches the profile back to its current generation in 5
	## minutes, replacing one an earlier switch left. It names the
	## generation rather than stepping back one, which goes too far when
	## the switch makes no new generation.
	arming =
		\\link=$(readlink "$1") || exit
		\\generation=$(printf %s "$link" | tr -cd 0-9)
		\\profile=$1
		\\shift
		\\unit=kai-rollback
		\\"$@" systemctl stop "$unit.timer" "$unit.service" 2>/dev/null
		\\"$@" systemctl reset-failed "$unit.timer" "$unit.service" 2>/dev/null
		\\back='nix-env --profile "$1" --switch-generation "$2" &&'
		\\back="$back"' exec "$1/bin/switch-to-configuration" switch'
		\\run="systemd-run --quiet --unit=$unit --on-active=300"
		\\run="$run --timer-property=AccuracySec=1s"
		\\run="$run --setenv=PATH=/run/current-system/sw/bin"
		\\exec "$@" $run sh -c "$back" sh "$profile" "$generation"

	## Activates the system profile `$1` as root through the words after it,
	## sudo or none, its output on stderr, then prints the profile's link.
	activation =
		\\profile=$1
		\\shift
		\\"$@" "$profile/bin/switch-to-configuration" switch >&2 || exit
		\\readlink "$profile"

	## Prints the system profile `$1`'s link, then each generation's link
	## and the time it was made, oldest first.
	listing =
		\\readlink "$1" || exit
		\\cd "$(dirname "$1")" || exit
		\\stat -c '%n %y' "$(basename "$1")"-*-link | sort -t- -k2,2n

	## `argv` with its stdout written to `file`, which is in the generated
	## root, so that a continuation reads it.
	recorded : Str, List(Str) -> List(Str)
	recorded = |file, argv| {
		script =
			\\file=$1
			\\shift
			\\mkdir -p "$(dirname "$file")" || exit
			\\"$@" >"$file"
		["sh", "-c", script, "sh", file].concat(argv)
	}

	## What a switch or rollback at `destination` says once it has run, or
	## the generations a listing prints, from what it recorded.
	report : Machine, Context, Str, [Here, Remote(Str)] -> Planned
	report = |m, ctx, action, destination| {
		file = NixosBackend.generations_file(ctx)
		lines = match ctx.observed.find_first(|o| o.path == file) {
			Ok({ contents: Text(text), .. }) => text.split_on("\n").drop_if(Str.is_empty)
			_ => return Err(Plan.fail("kai machine ${action} recorded no ${file}"))
		}
		current = lines.first() ?? ""
		place = match destination {
			Here => "this host"
			Remote(target) => target
		}
		generation = NixosBackend.generation(current)
		running = "is now running generation ${generation}"
		steps = if action == "generations" {
			lines.drop_first(1).map(
				|line| {
					(link, made) = match line.split_first(" ") {
						Ok({ before, after }) => (before, after)
						Err(_) => (line, "")
					}
					# stat's time, such as 2026-11-14 10:03:12.5 +0000, to the minute.
					minute = Str.join_with(made.split_on(":").take_first(2), ":")
					marker = if (link == current) "  (current)" else ""
					Print("generation ${NixosBackend.generation(link)}  ${minute}${marker}")
				},
			)
		} else if action == "switch" {
			[Note("${MachineModel.called(m)} ${running} on ${place}")]
		} else {
			[Note("${place} ${running}")]
		}
		Ok(Plan.{ steps, next: Done })
	}

	## The generation a system profile's link names: 43 for system-43-link.
	generation : Str -> Str
	generation = |link| link.drop_prefix("system-").drop_suffix("-link")

	## Installing erases the Disk of the server at `target`, any Linux that
	## logs in over SSH as root or with sudo, and installs the machine with
	## nixos-anywhere from the project's locked nixpkgs. The system, and
	## the kexec installer nixos-anywhere boots the server into, of the same
	## nixpkgs as the disko it runs there, are built here first, so what
	## fails to build fails before anything is erased. nixos-anywhere then
	## records the server's hardware with nixos-facter in the project, and
	## builds the system again with it.
	install : Project, List(Machine), Machine, Context, Str -> Planned
	install = |project, machines, m, ctx, target| {
		description = "machine install ${MachineModel.named(m)} on ${target}"
		tools = ExpectPrograms({ description, programs: ["nix", "ssh"] })
		built = NixosBackend.build(project, machines, m, ctx, "")?
		installer_link = "${ctx.layout.workspace}/machines/${m.instance}-installer"
		installer = NixosBackend.flake_build(
			project,
			machines,
			ctx,
			{
				attribute: "kexecInstallers.${m.system}",
				name: "${m.instance}-installer",
				description: "machine install ${MachineModel.named(m)}: installer",
				out_link: installer_link,
			},
		)?
		# The system's build has written the flake already.
		installer_build = installer.steps.keep_if(
			|step|
				match step {
					Run(_) => Bool.True
					_ => Bool.False
				},
		)
		tarball = "${installer_link}/nixos-kexec-installer-noninteractive-"
			.concat("${m.system}.tar.gz")
		device = match m.disk {
			SingleDisk(path) => path
			NoDisk => ""
		}
		prompt = "Install ${MachineModel.called(m)} on ${target}, ERASING its disk "
			.concat("${device} and everything on it?")
		flake = "path:${Std.nix_layout(ctx.layout).generated_root}"
		anywhere = if m.operators.is_empty() {
			NixosBackend.nixos_anywhere(flake, m.instance, target)
		} else {
			NixosBackend.keyed_install(ctx, flake, m, target)
		}
		facts = NixosBackend.facts_file(m, ctx.layout.project_root)
		recording = ["--kexec", tarball]
			.concat(["--generate-hardware-config", "nixos-facter", facts])
		# nixos-anywhere's progress shows, as it runs for minutes and may stall.
		run = NixosBackend.run(description, Inherit, anywhere.concat(recording))
		installing = Note(
			"installing ${MachineModel.called(m)} on ${target}: this erases ${device} "
				.concat("and takes several minutes"),
		)
		wrote = Note("wrote ${facts}, the machine's hardware facts; commit it")
		steps = [tools]
			.concat(built.steps)
			.concat(installer_build)
			.concat([Confirm(prompt), installing, run, wrote])
		Ok(Plan.{ steps, next: Done })
	}

	## nixos-anywhere from the locked nixpkgs on machine `name` of `flake`.
	nixos_anywhere : Str, Str, Str -> List(Str)
	nixos_anywhere = |flake, name, target| {
		script =
			\\flake=$1
			\\shift
			\\exec nix run --inputs-from "$flake" default#nixos-anywhere -- "$@"
		["sh", "-c", script, "sh", flake]
			.concat(NixosBackend.anywhere_arguments(flake, name, target))
	}

	## nixos-anywhere's arguments for machine `name` of `flake` on `target`. The
	## machine's module files and hardware facts are read by their absolute
	## paths, which pure evaluation refuses, as `kai machine build`'s --impure
	## allows. Flake commands ignore `pure-eval` from NIX_CONFIG, so it is an
	## option, which nixos-anywhere passes to each of its nix commands. A
	## target's port is its own option, and holds once the server has booted
	## the installer, as through a port forward to port 22.
	anywhere_arguments : Str, Str, Str -> List(Str)
	anywhere_arguments = |flake, name, target| {
		reach = NixosBackend.ssh_target(target)
		port = if reach.port.is_empty() {
			[]
		} else {
			["--ssh-port", reach.port, "--post-kexec-ssh-port", reach.port]
		}
		["--flake", "${flake}#${name}", "--target-host", reach.destination]
			.concat(port)
			.concat(["--option", "pure-eval", "false"])
	}

	## nixos-anywhere as `nixos_anywhere` runs it, placing machine `m`'s SSH
	## host key with `--extra-files`. The key is decrypted from
	## secrets/hosts/NAME.age with the operator's identity, or else made
	## here, encrypted to the Operators there, its public key written to
	## secrets/hosts/NAME.pub, and the machine's secrets encrypted again to
	## it. The key exists in plaintext only in the script's own temporary
	## directory, which holds the files nixos-anywhere copies in a
	## directory of its own.
	keyed_install : Context, Str, Machine, Str -> List(Str)
	keyed_install = |ctx, flake, m, target| {
		arguments =
			\\flake=$1 identity=$2 secrets=$3 name=$4 operators=$5
			\\shift 5
		installing =
			\\echo "$operators" >"$work/operators"
			\\files=$work/files
			\\mkdir -p "$files/etc/ssh" || exit
			\\chmod 755 "$files" "$files/etc" "$files/etc/ssh"
			\\key=$files/etc/ssh/ssh_host_ed25519_key
			\\stored=$secrets/hosts/$name
			\\if [ -e "$stored.age" ]; then
			\\  age -d -i "$identity" -o "$key" "$stored.age" || exit
			\\  ssh-keygen -y -f "$key" >"$key.pub" || exit
			\\  [ -e "$stored.pub" ] || cp "$key.pub" "$stored.pub" || exit
			\\else
			\\  ssh-keygen -q -t ed25519 -N '' -C "root@$name" -f "$key" || exit
			\\  cat "$work/operators" "$key.pub" >"$work/recipients" || exit
			\\  for secret in "$secrets/$name"/*.age; do
			\\    [ -e "$secret" ] && reencrypt "$secret" "$work/recipients"
			\\  done
			\\  age -R "$work/operators" -o "$work/host.age" "$key" || exit
			\\  mkdir -p "$secrets/hosts" || exit
			\\  mv "$work/host.age" "$stored.age" || exit
			\\  cp "$key.pub" "$stored.pub" || exit
			\\  echo "wrote $stored.age, the new host key encrypted to Operators" >&2
			\\  echo "wrote $stored.pub, its public key" >&2
			\\fi
			\\chmod 600 "$key"
			\\chmod 644 "$key.pub"
			\\anywhere=default#nixos-anywhere
			\\nix run --inputs-from "$flake" "$anywhere" -- "$@" --extra-files "$files"
		script = [arguments, NixosBackend.decrypting, installing]
		identity = Command.path(ctx.args, "identity") ?? ""
		secrets = "${ctx.layout.project_root}/secrets"
		NixosBackend.with_age(flake, Str.join_with(script, "\n"))
			.concat([flake, identity, secrets, m.instance])
			.append(Str.join_with(m.operators, "\n"))
			.concat(NixosBackend.anywhere_arguments(flake, m.instance, target))
	}

	## `sh -c script sh` with age and ssh-keygen from the locked nixpkgs of
	## `flake` on PATH; the script's arguments follow.
	with_age : Str, Str -> List(Str)
	with_age = |flake, script|
		["nix", "shell", "--inputs-from", flake, "default#age", "default#openssh"]
			.concat(["--command", "sh", "-c", script, "sh"])

	## A private temporary directory, `$work`, removed however the script
	## ends; plaintext lives only there.
	temporary =
		\\umask 077
		\\work=$(mktemp -d) || exit
		\\trap 'rm -rf "$work"' EXIT
		\\trap 'exit 1' HUP INT TERM

	## `temporary`, the operator's `$identity`, ~/.ssh/id_ed25519 when "",
	## and `reencrypt FILE RECIPIENTS`, which decrypts FILE with it into
	## `$work` and encrypts it again, in place, to the keys in RECIPIENTS.
	decrypting = {
		reencrypt =
			\\[ -n "$identity" ] || identity=$HOME/.ssh/id_ed25519
			\\reencrypt() {
			\\  age -d -i "$identity" -o "$work/plain" "$1" || exit
			\\  age -R "$2" -o "$work/encrypted" "$work/plain" || exit
			\\  rm -f "$work/plain"
			\\  mv "$work/encrypted" "$1" || exit
			\\  echo "re-encrypted $1" >&2
			\\}
		Str.join_with([NixosBackend.temporary, reencrypt], "\n")
	}

	## Writes `$work/operators` and `$work/recipients`: the Operators, and
	## the host public key too when it is known; else says so and `$5`.
	recipients =
		\\echo "$operators" >"$work/operators"
		\\cp "$work/operators" "$work/recipients" || exit
		\\host=$secrets/hosts/$name.pub
		\\if [ -e "$host" ]; then
		\\  cat "$host" >>"$work/recipients" || exit
		\\else
		\\  echo "$host does not exist, so this encrypts to Operators only: $5" >&2
		\\fi

	## `kai secret set` and `kai secret rekey` for the machine and secret
	## `kai secret` names: each writes std's flake, whose locked nixpkgs
	## provides age, then runs its script. Neither builds the machine.
	secret_implementation : Project, List(Machine) -> Implementation
	secret_implementation = |project, machines|
		Implementation.{
			command: "secret",
			backend: On("nix"),
			# Unknown names are refused while planning, with suggestions.
			fit: |_| Ok({}),
			plan: |ctx| {
				(m, secret) = MachineModel.secret_target(machines, ctx.args)?
				action = Command.name(ctx.args, "action")
				description = "secret ${action} ${MachineModel.named(m)}"
				tools = ExpectPrograms({ description, programs: ["nix"] })
				flake = NixosBackend.flake_output(project, machines, m, ctx, "")?
				written = flake.steps.drop_if(
					|step|
						match step {
							Run(_) => Bool.True
							_ => Bool.False
						},
				)
				nix_flake = "path:${Std.nix_layout(ctx.layout).generated_root}"
				secrets = "${ctx.layout.project_root}/secrets"
				operators = Str.join_with(m.operators, "\n")
				unknown_host = NixosBackend.without_host_key(m)
				argv = if action == "set" {
					NixosBackend.with_age(nix_flake, NixosBackend.set_script)
						.concat([secrets, m.instance, secret, operators, unknown_host])
				} else {
					identity = Command.path(ctx.args, "identity") ?? ""
					NixosBackend.with_age(nix_flake, NixosBackend.rekey_script)
						.concat([identity, secrets, m.instance, operators, unknown_host])
				}
				steps = [tools]
					.concat(written)
					.append(NixosBackend.run(description, Inherit, argv))
				Ok(Plan.{ steps, next: Done })
			},
		}

	## Why a machine without a host public key cannot decrypt its secrets
	## yet, and what fixes it.
	without_host_key : Machine -> Str
	without_host_key = |m| {
		name = MachineModel.named(m)
		"kai machine install ${name} makes the machine's host key and encrypts "
			.concat("its secrets to it; for a machine installed otherwise, write ")
			.concat("its /etc/ssh/ssh_host_ed25519_key.pub there and run kai ")
			.concat("secret rekey ${name}")
	}

	## Encrypts stdin, which never touches a disk, to the recipients, as
	## secrets/NAME/SECRET.age.
	set_script = {
		arguments =
			\\secrets=$1 name=$2 secret=$3 operators=$4
		encrypt =
			\\age -R "$work/recipients" -o "$work/encrypted" || exit
			\\mkdir -p "$secrets/$name" || exit
			\\mv "$work/encrypted" "$secrets/$name/$secret.age" || exit
			\\echo "wrote $secrets/$name/$secret.age" >&2
		parts = [arguments, NixosBackend.temporary, NixosBackend.recipients, encrypt]
		Str.join_with(parts, "\n")
	}

	## Encrypts each of the machine's secrets again to the recipients, and
	## its host key to the Operators.
	rekey_script = {
		arguments =
			\\identity=$1 secrets=$2 name=$3 operators=$4
		rekey =
			\\for secret in "$secrets/$name"/*.age; do
			\\  [ -e "$secret" ] && reencrypt "$secret" "$work/recipients"
			\\done
			\\if [ -e "$secrets/hosts/$name.age" ]; then
			\\  reencrypt "$secrets/hosts/$name.age" "$work/operators"
			\\fi
		parts = [arguments, NixosBackend.decrypting, NixosBackend.recipients, rekey]
		Str.join_with(parts, "\n")
	}

	## The machine's architecture, as `uname -m` prints it.
	architecture : Machine -> Str
	architecture = |m|
		match m.system.split_first("-") {
			Ok({ before, .. }) => before
			Err(_) => m.system
		}

	## How ssh reaches `target`, an SSH target `MachineModel.parse_target`
	## takes: its `destination`, `user@host` or `host`, and its `port`, ""
	## for ssh's own, which `options` name as ssh takes it. Neither the
	## destination nor an `ssh-ng://` store URL holds the port.
	ssh_target : Str -> { destination : Str, port : Str, options : List(Str) }
	ssh_target = |target| {
		{ user, host, port } = MachineModel.parse_target(target)
			?? { user: "", host: target, port: "" }
		destination = if (user.is_empty()) host else "${user}@${host}"
		options = if (port.is_empty()) [] else ["-p", port]
		{ destination, port, options }
	}

	## A shell check, as the switch runs, that `target` runs NixOS on the
	## machine's architecture, connecting with ssh `options` and its port.
	## The target, the messages and the options are arguments, never part
	## of the script; when ssh fails, it exits with ssh's status.
	remote_check : Machine, Str, List(Str) -> List(Str)
	remote_check = |m, target, options| {
		reach = NixosBackend.ssh_target(target)
		script =
			\\target=$1 destination=$2 architecture=$3 machine=$4 install=$5
			\\shift 5
			\\found=$(ssh "$@" "$destination" -- 'uname -m && test -e /etc/NIXOS')
			\\status=$?
			\\[ "$status" -gt 1 ] && exit "$status"
			\\if [ "$found" != "$architecture" ]; then
			\\  echo "$target is $found, not $architecture: $machine" >&2
			\\  exit 1
			\\fi
			\\[ "$status" = 0 ] && exit 0
			\\echo "$target does not run NixOS: $install" >&2
			\\exit 1
		[
			"sh",
			"-c",
			script,
			"sh",
			target,
			reach.destination,
			NixosBackend.architecture(m),
			"${MachineModel.called(m)} is ${m.system}",
			"run kai machine install ${MachineModel.named(m)} --to ${target} first",
		]
			.concat(reach.options)
			.concat(options)
	}

	## A shell step setting `target`'s system profile to the store path
	## `link` names, known only once the build has run: `command`, quoted
	## for the remote shell, then the store path, which holds no quote. ssh
	## connects with the target's port and `options`, the last arguments.
	remote_profile : Str, Str, List(Str), List(Str) -> List(Str)
	remote_profile = |link, target, command, options| {
		reach = NixosBackend.ssh_target(target)
		script =
			\\link=$1 target=$2 command=$3
			\\shift 3
			\\store_path=$(readlink -f "$link") || exit
			\\case $store_path in
			\\/nix/store/*[!A-Za-z0-9/+._?=-]*) ;;
			\\/nix/store/?*) exec ssh "$@" "$target" -- "$command '$store_path'" ;;
			\\esac
			\\echo "unexpected store path: $store_path" >&2
			\\exit 1
		quoted = Str.join_with(command.map(NixosBackend.shell_quote), " ")
		["sh", "-c", script, "sh", link, reach.destination, quoted]
			.concat(reach.options)
			.concat(options)
	}

	## `word` as one word for a POSIX shell: bare when it holds only plain
	## characters, else single-quoted.
	shell_quote : Str -> Str
	shell_quote = |word| {
		plain = |b|
			(b >= 'a' and b <= 'z')
				or (b >= 'A' and b <= 'Z')
				or (b >= '0' and b <= '9')
				or "/._-+=:@,%".to_utf8().contains(b)
		if !word.is_empty() and word.to_utf8().all(plain) {
			word
		} else {
			"'${word.replace_each("'", "'\\''")}'"
		}
	}

	## `kai machine build`'s plan, leaving `out_link` ("" for none). A
	## missing secret fails before the build, naming the command that sets
	## it.
	build : Project, List(Machine), Machine, Context, Str -> Planned
	build = |project, machines, machine, ctx, out_link| {
		root = ctx.layout.project_root
		built = NixosBackend.flake_output(project, machines, machine, ctx, out_link)?
		checks = machine.modules.map(|path| CheckSource("${root}/${path}"))
		files = machine.secrets.map(|s| NixosBackend.secret_file(machine, s, root))
		found = if files.is_empty() {
			[]
		} else {
			script =
				\\name=$1 instance=$2
				\\shift 2
				\\for file; do
				\\  [ -e "$file" ] && continue
				\\  secret=$(basename "$file" .age)
				\\  set="kai secret set $name $secret$instance"
				\\  echo "$file does not exist: run $set" >&2
				\\  exit 1
				\\done
			description = "machine build ${MachineModel.named(machine)}: secrets"
			# A secret of an instance is set naming it.
			instance = if machine.instance == machine.name {
				""
			} else {
				" --as ${machine.instance}"
			}
			argv = ["sh", "-c", script, "sh", machine.name, instance].concat(files)
			checked = files.map(|file| CheckSource(file))
			[NixosBackend.run(description, Quiet, argv)].concat(checked)
		}
		Ok(Plan.{ steps: checks.concat(found).concat(built.steps), next: built.next })
	}

	## std's flake with every machine, and the build of `machine`'s system.
	flake_output : Project, List(Machine), Machine, Context, Str -> Planned
	flake_output = |project, machines, machine, ctx, out_link| {
		attribute = "nixosConfigurations.${machine.instance}"
			.concat(".config.system.build.toplevel")
		description = "machine build ${MachineModel.named(machine)}"
		wanted = { attribute, name: machine.instance, description, out_link }
		NixosBackend.flake_build(project, machines, ctx, wanted)
	}

	## std's flake with every machine, and the build `wanted` describes.
	flake_build : Project, List(Machine), Context, Built -> Planned
	flake_build = |project, machines, ctx, wanted|
		Std.build_flake_output(
			project,
			ctx,
			{
				outputs: NixosBackend.outputs(machines, ctx.layout.project_root),
				environments: machines
					.keep_if(|m| !m.environment.is_empty())
					.map(|m| m.environment),
				attribute: wanted.attribute,
				name: wanted.name,
				description: wanted.description,
				out_link: wanted.out_link,
			},
		)

	## Where install records machine `m`'s hardware facts, beneath
	## `project_root`.
	facts_file : Machine, Str -> Str
	facts_file = |m, project_root|
		"${project_root}/machines/${m.instance}/facter.json"

	## Where secret `s` of machine `m` is encrypted, beneath `project_root`.
	secret_file : Machine, MachineModel.Secret, Str -> Str
	secret_file = |m, s, project_root|
		"${project_root}/secrets/${m.instance}/${s.name}.age"

	## Why `action` refuses another host than `m`.
	local_only : Str, Machine -> Str
	local_only = |action, m| {
		# An instance never acts on Host, the machine's own server.
		reaching = if (m.instance == m.name) "Host or --to" else "--to"
		host_name = MachineModel.host_name(m)
		"kai machine ${action} ${MachineModel.named(m)} without ${reaching} acts "
			.concat("on the host it runs on; run it on ${host_name}, or name its ")
			.concat("SSH target with ${reaching}")
	}

	## A shell check, as the switch runs, that this host's name is the
	## machine's HostName. The names and the message are arguments, never
	## part of the script.
	host_check : Str, Machine -> List(Str)
	host_check = |action, m| {
		script =
			\\host=$(uname -n)
			\\[ "$host" = "$1" ] && exit 0
			\\echo "this host is $host, not $1: $2" >&2
			\\exit 1
		why = NixosBackend.local_only(action, m)
		["sh", "-c", script, "sh", MachineModel.host_name(m), why]
	}

	run : Str, Plan.Output, List(Str) -> Plan.Step
	run = |description, output, argv|
		Run({
			description,
			argv,
			output,
			secrets: [],
			removed_environment_variables: [],
			kept_environment_variables: [],
		})

	## The flake outputs defining every machine, with module paths beneath
	## `project_root`, and, when one has a Disk, the noninteractive kexec
	## installer nixos-images builds for each system, which install boots;
	## "" when there are none.
	outputs : List(Machine), Str -> Str
	outputs = |machines, project_root|
		if machines.is_empty() {
			""
		} else {
			defined = machines.map(|m| NixosBackend.machine(m, project_root))
			# nixos-images names it unstable, but both its nixpkgs follow the
			# project's.
			installers =
				\\      kexecInstallers = builtins.mapAttrs
				\\        (system: packages:
				\\          packages.kexec-installer-nixos-unstable-noninteractive)
				\\        inputs."nixos-images".packages;
				\\
			"      nixosConfigurations = {\n"
				.concat(Str.join_with(defined, ""))
				.concat("      };\n")
				.concat(if (machines.any(|m| m.disk != NoDisk)) installers else "")
		}

	machine : Machine, Str -> Str
	machine = |m, project_root| {
		file = |path| "(/. + ${NixosBackend.quote("${project_root}/${path}")})"
		# A file of a locked input is in the store, so reading it is pure.
		input_file = |{ input, path }|
			"(inputs.${NixosBackend.quote(input)} + ${NixosBackend.quote("/${path}")})"
		settings = NixosBackend.settings(m, project_root)
		NixosBackend.lines(
			[
				"        ${NixosBackend.quote(m.instance)} = "
					.concat("inputs.\"default\".lib.nixosSystem {"),
				"          specialArgs = { inherit inputs; };",
				"          modules = [",
				"            {",
			]
				.concat(settings.map(|line| "              ${line}"))
				.append("            }")
				.concat(m.modules.map(|path| "            ${file(path)}"))
				.concat(m.input_modules.map(input_file).map(|line| "            ${line}"))
				.concat(["          ];", "        };"]),
		)
	}

	## The typed settings as NixOS option definitions.
	settings : Machine, Str -> List(Str)
	settings = |m, project_root| {
		quote = NixosBackend.quote
		strings = |items| NixosBackend.list(items.map(quote))
		ports = |items| NixosBackend.list(items.map(U16.to_str))
		users = m.users.join_map(
			|u| {
				keys = "openssh.authorizedKeys.keys = ${strings(u.keys)};"
				if u.name == "root" {
					["users.users.root.${keys}"]
				} else {
					[
						"users.users.${quote(u.name)} = {",
						"  isNormalUser = true;",
						"  extraGroups = ${strings(u.groups)};",
						"  ${keys}",
						"};",
					]
				}
			},
		)
		# Only keys log in, root's only when it has some.
		root_keys = m.users.keep_if(|u| u.name == "root").join_map(|u| u.keys)
		root_login = if (root_keys.is_empty()) "no" else "prohibit-password"
		ssh = [
			"services.openssh = {",
			"  enable = true;",
			"  settings.PasswordAuthentication = false;",
			"  settings.KbdInteractiveAuthentication = false;",
			"  settings.PermitRootLogin = ${quote(root_login)};",
			"};",
		]
		firewall = |protocol, list|
			"networking.firewall.allowed${protocol}Ports = ${ports(list)};"
		tcp_ports = MachineModel.open_tcp_ports(m)
		udp_ports = MachineModel.open_udp_ports(m)
		# mkShell puts an environment's packages in nativeBuildInputs.
		shell = "(environmentsFor ${quote(m.system)}).${quote(m.environment)} { }"
		system_packages = [
			"environment.systemPackages =",
			"  (${shell}).nativeBuildInputs;",
		]
		when = |present, lines| if (present) lines else []
		# Host's user copies the system in with `nix copy`, which only a
		# trusted user may do; root stays trusted.
		host_user = MachineModel.target_user(m.host)
		trusted = host_user != "root" and m.users.any(|u| u.name == host_user)
		trusted_users = "nix.settings.trusted-users = "
			.concat("${strings(["root", host_user])};")
		disko = "inputs.\"disko\".nixosModules.disko"
		agenix = "inputs.\"agenix\".nixosModules.default"
		imported = when(m.disk != NoDisk, [disko])
			.concat(when(!m.secrets.is_empty(), [agenix]))
		import_line = "imports = ${NixosBackend.list(imported)};"
		# The facts install records, once it has: NixOS's facter module loads
		# the kernel modules and firmware the server's hardware needs.
		facts = "/. + ${quote(NixosBackend.facts_file(m, project_root))}"
		facter = [
			"hardware.facter.reportPath = let report = ${facts}; in",
			"  if builtins.pathExists report then report else null;",
		]
		# agenix decrypts each secret with the host key install placed, or
		# the one OpenSSH made, into /run/secrets.
		file = |s| "(/. + ${quote(NixosBackend.secret_file(m, s, project_root))})"
		secrets = ["age.identityPaths = [ \"/etc/ssh/ssh_host_ed25519_key\" ];"]
			.concat(
				m.secrets.join_map(
					|s| [
						"age.secrets.${quote(s.name)} = {",
						"  file = ${file(s)};",
						"  owner = ${quote(s.owner)};",
						"  group = ${quote(s.group)};",
						"  mode = ${quote(s.mode)};",
						"  path = ${quote("/run/secrets/${s.name}")};",
						"};",
					],
				),
			)
		[
			"nixpkgs.hostPlatform = ${quote(m.system)};",
			"networking.hostName = ${quote(MachineModel.host_name(m))};",
			"system.stateVersion = ${quote(m.state_version)};",
		]
			.concat(
				when(
					!m.time_zone.is_empty(),
					["time.timeZone = ${quote(m.time_zone)};"],
				),
			)
			.concat(users)
			.concat(when(trusted, [trusted_users]))
			.concat(when(m.ssh, ssh))
			.concat(when(!tcp_ports.is_empty(), [firewall("TCP", tcp_ports)]))
			.concat(when(!udp_ports.is_empty(), [firewall("UDP", udp_ports)]))
			.concat(when(!m.environment.is_empty(), system_packages))
			.concat(when(!imported.is_empty(), [import_line]))
			.concat(NixosBackend.disk(m.disk))
			.concat(when(m.disk != NoDisk, facter))
			.concat(when(!m.secrets.is_empty(), secrets))
			.concat(m.services.join_map(|Caddy(server)| NixosBackend.caddy(server)))
	}

	## Caddy as NixOS's services.caddy: one virtual host per site, whose
	## Caddyfile lines Caddy.problems has made sure hold no syntax of their
	## own. The firewall opens its ports beside Firewall's.
	caddy : Caddy.Server -> List(Str)
	caddy = |server| {
		quote = NixosBackend.quote
		email = if server.email.is_empty() {
			[]
		} else {
			["services.caddy.email = ${quote(server.email)};"]
		}
		sites = server.sites.map(
			|site| {
				caddyfile = match site.target {
					ReverseProxy(upstream) => "reverse_proxy ${upstream}"
					Files(root) => "root * ${root}\nfile_server"
				}
				"services.caddy.virtualHosts.${quote(site.domain)}.extraConfig = "
					.concat("${quote(caddyfile)};")
			},
		)
		["services.caddy.enable = true;"].concat(email).concat(sites)
	}

	## A Disk as disko's NixOS module and its layout, with GRUB booting on
	## BIOS and UEFI: nixos-anywhere's example layout. disko adds the disk
	## to GRUB's devices and defines the file systems.
	disk : MachineModel.Disk -> List(Str)
	disk = |layout|
		match layout {
			NoDisk => []
			SingleDisk(device) => [
				"disko.devices.disk.main = {",
				"  type = \"disk\";",
				"  device = ${NixosBackend.quote(device)};",
				"  content = {",
				"    type = \"gpt\";",
				"    partitions = {",
				"      boot = { size = \"1M\"; type = \"EF02\"; };",
				"      ESP = {",
				"        size = \"512M\";",
				"        type = \"EF00\";",
				"        content = {",
				"          type = \"filesystem\";",
				"          format = \"vfat\";",
				"          mountpoint = \"/boot\";",
				"          mountOptions = [ \"umask=0077\" ];",
				"        };",
				"      };",
				"      root = {",
				"        size = \"100%\";",
				"        content = {",
				"          type = \"filesystem\";",
				"          format = \"ext4\";",
				"          mountpoint = \"/\";",
				"        };",
				"      };",
				"    };",
				"  };",
				"};",
				"boot.loader.grub = {",
				"  efiSupport = true;",
				"  efiInstallAsRemovable = true;",
				"};",
			]
		}

	list : List(Str) -> Str
	list = |items|
		if (items.is_empty()) "[ ]" else "[ ${Str.join_with(items, " ")} ]"

	lines : List(Str) -> Str
	lines = |items| items.fold("", |text, line| text.concat(line).concat("\n"))

	## A Nix string holding exactly `value`: interpolation cannot inject an
	## expression.
	quote : Str -> Str
	quote = |value| {
		escaped = value
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("\${", "\\\${")
			.replace_each("\n", "\\n")
			.replace_each("\r", "\\r")
			.replace_each("\t", "\\t")
		"\"${escaped}\""
	}
}
