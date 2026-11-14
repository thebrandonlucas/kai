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
## absolute path. Modules receive the flake's `inputs` as an argument.
NixosBackend :: [].{

	Project : List(Config.Setting)

	Planned : Try(Plan, Plan.Failure)

	Context : Implementation.Context

	implementation : Project, List(Machine) -> Implementation
	implementation = |project, machines|
		Implementation.{
			command: "machine",
			backend: On("nix"),
			fit: |args| MachineModel.requested(machines, args).map_ok(|_| {}),
			plan: |ctx| {
				m = MachineModel.requested(machines, ctx.args).map_err(Plan.fail)?
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
					match destination {
						Here => NixosBackend.on_host(project, machines, m, ctx, action)
						Remote(target) =>
							NixosBackend.on_remote(project, machines, m, ctx, action, target)
					}
				}
			},
		}

	## What only Nix can honour that is wrong with machine `m` in `project`.
	problems : Project, Machine -> List(Str)
	problems = |project, m| {
		modules = m.modules
			.drop_if(NixosBackend.valid_module_path)
			.map(|path| "module ${path} is no .nix file inside the project")
		declared = |input|
			project.any(
				|setting|
					match setting {
						Input(name, _) => name.to_str() == input
						_ => Bool.False
					},
			)
		missing = |needed, setting, input|
			if needed and !declared(input) {
				declaration = NixosBackend.input(input)
				["${setting} needs ${input}; add ${declaration} to std's settings"]
			} else {
				[]
			}
		modules
			.concat(missing(m.disk != NoDisk, "Disk", "disko"))
			.concat(missing(!m.secrets.is_empty(), "Secrets", "agenix"))
	}

	## The std setting declaring the flake input a Disk's or Secrets' module
	## comes from.
	input : Str -> Str
	input = |name|
		if name == "disko" {
			"Input(\"disko\", \"github:nix-community/disko\")"
		} else {
			"Input(\"agenix\", \"github:ryantm/agenix\")"
		}

	## A relative path to a .nix file that stays inside the project.
	valid_module_path : Str -> Bool
	valid_module_path = |path|
		path.ends_with(".nix")
			and path.split_on("/").all(|s| !s.is_empty() and s != "." and s != "..")

	## NixOS's system profile, whose generations are the host's systems.
	profile = "/nix/var/nix/profiles/system"

	## Switching, rolling back and listing act on this host, which must be
	## the machine: its System now, its HostName as the plan runs. Only the
	## profile and the activation run as root.
	on_host : Project, List(Machine), Machine, Context, Str -> Planned
	on_host = |project, machines, m, ctx, action| {
		if ctx.host.system != m.system {
			return Err(
				Plan.fail(
					"machine ${m.name} is ${m.system}, but this host is ${ctx.host.system}: "
						.concat(NixosBackend.local_only(action, m)),
				),
			)
		}
		description = "machine ${action} ${m.name}"
		system_profile = NixosBackend.profile
		check = NixosBackend.host_check(action, m)
		here = NixosBackend.run("${description}: host check", Quiet, check)
		sudo = |argv| NixosBackend.run(description, Inherit, ["sudo"].concat(argv))
		activate = sudo(["${system_profile}/bin/switch-to-configuration", "switch"])
		restarting = "restarting changed services and booting it by default?"
		steps = match action {
			"switch" => {
				link = "${ctx.layout.workspace}/machines/${m.name}"
				built = NixosBackend.build(project, machines, m, ctx, link)?
				prompt = "Switch this host to machine ${m.name}, ${restarting}"
				set = sudo(["nix", "build", "--no-link", "--profile", system_profile, link])
				[here].concat(built.steps).concat([Confirm(prompt), set, activate])
			}
			"rollback" => {
				prompt = "Switch this host back to its previous system, ${restarting}"
				# Steps the profile's link back a generation, as `nix-env
				# --rollback` does: it needs no `nix profile` manifest.
				back = sudo(["nix", "profile", "rollback", "--profile", system_profile])
				[here, Confirm(prompt), back, activate]
			}
			_ => {
				listed = ["nixos-rebuild", "list-generations"]
				[here, NixosBackend.run(description, Inherit, listed)]
			}
		}
		Ok(Plan.{ steps, next: Done })
	}

	## Switching, rolling back and listing act on `target` over SSH, which
	## must run NixOS on the machine's architecture. The system is built
	## here and copied there; only the profile and the activation run as
	## root there, through sudo unless the target logs in as root.
	on_remote : Project, List(Machine), Machine, Context, Str, Str -> Planned
	on_remote = |project, machines, m, ctx, action, target| {
		description = "machine ${action} ${m.name} on ${target}"
		system_profile = NixosBackend.profile
		programs = if (action == "switch") ["nix", "ssh"] else ["ssh"]
		tools = ExpectPrograms({ description, programs })
		check = NixosBackend.remote_check(m, target)
		there = NixosBackend.run("${description}: host check", Quiet, check)
		root = MachineModel.target_user(target) == "root"
		as_root = |argv| if (root) argv else ["sudo"].concat(argv)
		# The remote nix may not enable `nix profile` and `nix build`.
		nix = ["nix", "--extra-experimental-features", "nix-command"]
		# ssh joins the words for the remote shell, so each is quoted for it.
		remote = |argv| {
			words = ["ssh", target, "--"].concat(argv.map(NixosBackend.shell_quote))
			NixosBackend.run(description, Inherit, words)
		}
		activation = ["${system_profile}/bin/switch-to-configuration", "switch"]
		activate = remote(as_root(activation))
		restarting = "restarting changed services and booting it by default?"
		steps = match action {
			"switch" => {
				link = "${ctx.layout.workspace}/machines/${m.name}"
				built = NixosBackend.build(project, machines, m, ctx, link)?
				prompt = "Switch ${target} to machine ${m.name}, ${restarting}"
				store = "ssh-ng://${target}"
				copy = ["nix", "copy", "--substitute-on-destination", "--to", store, link]
				set_profile = ["build", "--no-link", "--profile", system_profile]
				set_command = as_root(nix.concat(set_profile))
				set = NixosBackend.remote_profile(link, target, set_command)
				[tools, there]
					.concat(built.steps)
					.concat([
						Confirm(prompt),
						NixosBackend.run(description, Inherit, copy),
						NixosBackend.run(description, Inherit, set),
						activate,
					])
			}
			"rollback" => {
				prompt = "Switch ${target} back to its previous system, ${restarting}"
				rollback = ["profile", "rollback", "--profile", system_profile]
				back = remote(as_root(nix.concat(rollback)))
				[tools, there, Confirm(prompt), back, activate]
			}
			_ => [tools, there, remote(["nixos-rebuild", "list-generations"])]
		}
		Ok(Plan.{ steps, next: Done })
	}

	## Installing erases the Disk of the server at `target`, any Linux that
	## logs in over SSH as root or with sudo, and installs the machine with
	## nixos-anywhere from the project's locked nixpkgs. The system is
	## built here first, so what fails to build fails before anything is
	## erased.
	install : Project, List(Machine), Machine, Context, Str -> Planned
	install = |project, machines, m, ctx, target| {
		description = "machine install ${m.name} on ${target}"
		tools = ExpectPrograms({ description, programs: ["nix", "ssh"] })
		built = NixosBackend.build(project, machines, m, ctx, "")?
		device = match m.disk {
			SingleDisk(path) => path
			NoDisk => ""
		}
		prompt = "Install machine ${m.name} on ${target}, ERASING its disk "
			.concat("${device} and everything on it?")
		flake = "path:${Std.nix_layout(ctx.layout).generated_root}"
		anywhere = if m.operators.is_empty() {
			NixosBackend.nixos_anywhere(flake, m.name, target)
		} else {
			NixosBackend.keyed_install(ctx, flake, m, target)
		}
		steps = [tools]
			.concat(built.steps)
			.concat([Confirm(prompt), NixosBackend.run(description, Inherit, anywhere)])
		Ok(Plan.{ steps, next: Done })
	}

	## nixos-anywhere from the locked nixpkgs on machine `name` of `flake`. The
	## machine's module files are read by their absolute paths, which pure
	## evaluation refuses, as `kai machine build`'s --impure allows: the script
	## adds `pure-eval = false` to any NIX_CONFIG the user has.
	nixos_anywhere : Str, Str, Str -> List(Str)
	nixos_anywhere = |flake, name, target| {
		script =
			\\flake=$1
			\\shift
			\\exec nix run --inputs-from "$flake" default#nixos-anywhere -- "$@"
		["sh", "-c", Str.join_with([NixosBackend.impure, script], "\n"), "sh", flake]
			.concat(["--flake", "${flake}#${name}", "--target-host", target])
	}

	## Adds `pure-eval = false` to any NIX_CONFIG the user has.
	impure =
		\\case $NIX_CONFIG in
		\\'') NIX_CONFIG='pure-eval = false' ;;
		\\*) NIX_CONFIG="$NIX_CONFIG
		\\pure-eval = false" ;;
		\\esac
		\\export NIX_CONFIG

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
		script = [arguments, NixosBackend.decrypting, NixosBackend.impure, installing]
		identity = Command.path(ctx.args, "identity") ?? ""
		secrets = "${ctx.layout.project_root}/secrets"
		NixosBackend.with_age(flake, Str.join_with(script, "\n"))
			.concat([flake, identity, secrets, m.name, Str.join_with(m.operators, "\n")])
			.concat(["--flake", "${flake}#${m.name}", "--target-host", target])
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
				description = "secret ${action} ${m.name}"
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
				unknown_host = NixosBackend.without_host_key(m.name)
				argv = if action == "set" {
					NixosBackend.with_age(nix_flake, NixosBackend.set_script)
						.concat([secrets, m.name, secret, operators, unknown_host])
				} else {
					identity = Command.path(ctx.args, "identity") ?? ""
					NixosBackend.with_age(nix_flake, NixosBackend.rekey_script)
						.concat([identity, secrets, m.name, operators, unknown_host])
				}
				steps = [tools]
					.concat(written)
					.append(NixosBackend.run(description, Inherit, argv))
				Ok(Plan.{ steps, next: Done })
			},
		}

	## Why a machine without a host public key cannot decrypt its secrets
	## yet, and what fixes it.
	without_host_key : Str -> Str
	without_host_key = |name|
		"kai machine install ${name} makes the machine's host key and encrypts "
			.concat("its secrets to it; for a machine installed otherwise, write ")
			.concat("its /etc/ssh/ssh_host_ed25519_key.pub there and run kai ")
			.concat("secret rekey ${name}")

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

	## A shell check, as the switch runs, that `target` runs NixOS on the
	## machine's architecture. The target and the messages are arguments,
	## never part of the script; when ssh fails, it exits with ssh's status.
	remote_check : Machine, Str -> List(Str)
	remote_check = |m, target| {
		script =
			\\found=$(ssh "$1" -- 'uname -m && test -e /etc/NIXOS')
			\\status=$?
			\\[ "$status" -gt 1 ] && exit "$status"
			\\if [ "$found" != "$2" ]; then
			\\  echo "$1 is $found, not $2: $3" >&2
			\\  exit 1
			\\fi
			\\[ "$status" = 0 ] && exit 0
			\\echo "$1 does not run NixOS: $4" >&2
			\\exit 1
		[
			"sh",
			"-c",
			script,
			"sh",
			target,
			NixosBackend.architecture(m),
			"machine ${m.name} is ${m.system}",
			"run kai machine install ${m.name} --to ${target} first",
		]
	}

	## A shell step setting `target`'s system profile to the store path
	## `link` names, known only once the build has run: `command`, quoted
	## for the remote shell, then the store path, which holds no quote.
	remote_profile : Str, Str, List(Str) -> List(Str)
	remote_profile = |link, target, command| {
		script =
			\\store_path=$(readlink -f "$1") || exit
			\\case $store_path in
			\\/nix/store/*[!A-Za-z0-9/+._?=-]*) ;;
			\\/nix/store/?*) exec ssh "$2" -- "$3 '$store_path'" ;;
			\\esac
			\\echo "unexpected store path: $store_path" >&2
			\\exit 1
		quoted = Str.join_with(command.map(NixosBackend.shell_quote), " ")
		["sh", "-c", script, "sh", link, target, quoted]
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
				\\name=$1
				\\shift
				\\for file; do
				\\  [ -e "$file" ] && continue
				\\  secret=$(basename "$file" .age)
				\\  echo "$file does not exist: run kai secret set $name $secret" >&2
				\\  exit 1
				\\done
			description = "machine build ${machine.name}: secrets"
			argv = ["sh", "-c", script, "sh", machine.name].concat(files)
			checked = files.map(|file| CheckSource(file))
			[NixosBackend.run(description, Quiet, argv)].concat(checked)
		}
		Ok(Plan.{ steps: checks.concat(found).concat(built.steps), next: built.next })
	}

	## std's flake with every machine, and the build of `machine`'s system.
	flake_output : Project, List(Machine), Machine, Context, Str -> Planned
	flake_output = |project, machines, machine, ctx, out_link| {
		attribute = "nixosConfigurations.${machine.name}"
			.concat(".config.system.build.toplevel")
		Std.build_flake_output(
			project,
			ctx,
			{
				outputs: NixosBackend.outputs(machines, ctx.layout.project_root),
				environments: machines
					.keep_if(|m| !m.environment.is_empty())
					.map(|m| m.environment),
				attribute,
				name: machine.name,
				description: "machine build ${machine.name}",
				out_link,
			},
		)
	}

	## Where secret `s` of machine `m` is encrypted, beneath `project_root`.
	secret_file : Machine, MachineModel.Secret, Str -> Str
	secret_file = |m, s, project_root|
		"${project_root}/secrets/${m.name}/${s.name}.age"

	## Why `action` refuses another host than `m`.
	local_only : Str, Machine -> Str
	local_only = |action, m|
		"kai machine ${action} without Host or --to acts on the host it runs "
			.concat("on; run it on ${m.host_name}, or name its SSH target with ")
			.concat("Host or --to")

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
		["sh", "-c", script, "sh", m.host_name, NixosBackend.local_only(action, m)]
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
	## `project_root`; "" when there are none.
	outputs : List(Machine), Str -> Str
	outputs = |machines, project_root|
		if machines.is_empty() {
			""
		} else {
			defined = machines.map(|m| NixosBackend.machine(m, project_root))
			"      nixosConfigurations = {\n"
				.concat(Str.join_with(defined, ""))
				.concat("      };\n")
		}

	machine : Machine, Str -> Str
	machine = |m, project_root| {
		file = |path| "(/. + ${NixosBackend.quote("${project_root}/${path}")})"
		settings = NixosBackend.settings(m, project_root)
		NixosBackend.lines(
			[
				"        ${NixosBackend.quote(m.name)} = "
					.concat("inputs.\"default\".lib.nixosSystem {"),
				"          specialArgs = { inherit inputs; };",
				"          modules = [",
				"            {",
			]
				.concat(settings.map(|line| "              ${line}"))
				.append("            }")
				.concat(m.modules.map(|path| "            ${file(path)}"))
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
			"networking.hostName = ${quote(m.host_name)};",
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
