# Pure Guix planning: an environment's tools become exact `guix shell
# --pure` argv under `guix time-machine`, at the channels Kai's lock pins.
import api.LockJson
import api.Plan as Steps
import ir.Ir
import ir.Project
import ir.Request

## Tool names are native Guix specifications, never translated from Nix
## names. Every Guix command runs under `guix time-machine` at the channel
## commits Kai's lock pins.
GuixBackend :: [].{

	## `guix shell` arguments for a shell or task, run under time-machine.
	plan : Ir, Request -> Try(List(Str), Str)
	plan = |ir, request| {
		project = Project.validate(ir)?
		(env_name, command) = match request {
			Request.Shell(name, argv) => {
				shell = project.shells.find_first(|s| s.name == name)
					.map_err(|_| "unknown shell: ${name}")?
				(shell.environment, argv)
			}
			Request.Run(name, extra) => {
				task = project.tasks.find_first(|t| t.name == name)
					.map_err(|_| "unknown task: ${name}")?
				(task.environment, task.run.concat(extra))
			}
			_ => return Err("Guix supports only kai shell and kai run")
		}
		Project.check_environment(project, Guix, env_name)?
		environment = project.environments.find_first(|e| e.name == env_name)
			.map_err(|_| "unknown environment: ${env_name}")?
		# Without specifications, guix shell would load a manifest from the
		# working directory instead.
		if environment.tools.is_empty() {
			return Err("a Guix shell needs at least one tool: ${environment.name}")
		}
		specs = environment.tools.map(|t| t.name)
		# A leading "-" would make a specification a guix option.
		if specs.any(|spec| spec.starts_with("-")) {
			return Err("invalid Guix tool in environment ${environment.name}")
		}
		tail = if command.is_empty() [] else ["--"].concat(command)
		Ok(["shell", "-q", "--pure"].concat(specs).concat(tail))
	}

	## A Guix channel as kai pins it: its commit is locked by `kai update`.
	Channel : {
		name : Str,
		url : Str,
		branch : Str,
		introduction : { commit : Str, signer : Str },
	}

	Pin : { channel : Channel, commit : Str }

	## The channel `%default-guix-channel` reports (Guix 1.5), which every
	## project on Guix uses.
	default_channel : Channel
	default_channel = {
		name: "guix",
		url: "https://git.guix.gnu.org/guix.git",
		branch: "master",
		introduction: {
			commit: "9edb3f66fd807b096b48283debdcddccfea34bad",
			signer: "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA",
		},
	}

	## A Scheme string literal for any text.
	quote : Str -> Str
	quote = |text| {
		escaped = text.replace_each("\\", "\\\\").replace_each("\"", "\\\"")
		"\"${escaped}\""
	}

	## channels.scm for `guix time-machine -C` (pinned) or the lock script
	## (unpinned).
	Entry : { channel : Channel, commit : [Unpinned, Pinned(Str)] }

	channels_scm : List(Entry) -> Str
	channels_scm = |entries| {
		q = GuixBackend.quote
		rendered = entries.map(
			|{ channel, commit }| {
				pinned = match commit {
					Pinned(hex) => "\n        (commit ${q(hex)})"
					Unpinned => ""
				}
				"(channel\n        (name '${channel.name})\n        (url ${q(channel.url)})"
					.concat("\n        (branch ${q(channel.branch)})${pinned}")
					.concat("\n        (introduction\n         (make-channel-introduction")
					.concat("\n          ${q(channel.introduction.commit)}")
					.concat("\n          (openpgp-fingerprint\n           ")
					.concat("${q(channel.introduction.signer)}))))")
			},
		)
		"(list ${Str.join_with(rendered, "\n      ")})\n"
	}

	## Run with `guix repl -q -- lock.scm RESULT CHANNELS`: resolves each
	## channel's branch head, authenticated by its introduction, and writes
	## the pins as JSON.
	lock_script : Str
	lock_script =
		\\;; kai's Guix lock script: resolve each channel's branch head,
		\\;; authenticated by its introduction, and write the pins as JSON.
		\\(use-modules (guix channels)
		\\             (guix store)
		\\             (guix openpgp)
		\\             (json)
		\\             (ice-9 match))
		\\
		\\(match (command-line)
		\\  ((_ result unpinned)
		\\   (let* ((channels (load unpinned))
		\\          (instances (with-store store
		\\                       (latest-channel-instances store channels)))
		\\          (pins (map (lambda (instance)
		\\                       (let ((channel (channel-instance-channel instance)))
		\\                         `((name . ,(symbol->string (channel-name channel)))
		\\                           (commit . ,(channel-instance-commit instance)))))
		\\                     instances)))
		\\     (call-with-output-file result
		\\       (lambda (port)
		\\         (scm->json `((channels . ,(list->vector pins))) port))))))
		\\

	## The lock script's result: a 40-hex commit for each channel asked for.
	pins : List(Channel), Str -> Try(List(Pin), Str)
	pins = |channels, text| {
		json = LockJson.decode(text)?
		found = LockJson.array(LockJson.field(json, "channels")?)?
		channels.map_try(
			|channel| {
				entry = found.find_first(
					|e| (LockJson.field(e, "name") ?? Null) == String(channel.name),
				)
					.map_err(|_| "Guix resolved no ${channel.name} channel")?
				commit = LockJson.string(LockJson.field(entry, "commit")?)?
				if GuixBackend.hex40(commit) {
					Ok({ channel, commit })
				} else {
					Err("Guix resolved an invalid commit for ${channel.name}")
				}
			},
		)
	}

	hex40 : Str -> Bool
	hex40 = |text| {
		digit = |b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')
		text.count_utf8_bytes() == 40 and text.to_utf8().all(digit)
	}

	## The lock's guix section: the channel names (its identity) and pins.
	section : List(Pin) -> LockJson
	section = |pinned|
		Object([
			{
				name: "identity",
				value: Object([
					{
						name: "channels",
						value: Array(pinned.map(|p| String(p.channel.name))),
					},
				]),
			},
			{
				name: "channels",
				value: Array(
					pinned.map(
						|p|
							Object([
								{ name: "name", value: String(p.channel.name) },
								{ name: "url", value: String(p.channel.url) },
								{ name: "branch", value: String(p.channel.branch) },
								{ name: "commit", value: String(p.commit) },
								{
									name: "introduction",
									value: Object([
										{ name: "commit", value: String(p.channel.introduction.commit) },
										{ name: "signer", value: String(p.channel.introduction.signer) },
									]),
								},
							]),
					),
				),
			},
		])

	## The pins a guix section holds for `channels`, or why it is missing
	## or stale.
	pinned : List(Channel), LockJson -> Try(List(Pin), Str)
	pinned = |channels, found| {
		stale = "the guix lock is missing or stale; run kai --backend guix update"
		entries = LockJson.array(LockJson.field(found, "channels")?)?
		channels.map_try(
			|channel| {
				entry = entries.find_first(
					|e| (LockJson.field(e, "name") ?? Null) == String(channel.name),
				)
					.map_err(|_| stale)?
				same = |name, value| LockJson.field(entry, name) == Ok(String(value))
				if !same("url", channel.url) or !same("branch", channel.branch) {
					return Err(stale)
				}
				commit = LockJson.string(LockJson.field(entry, "commit")?)?
				if GuixBackend.hex40(commit) Ok({ channel, commit }) else Err(stale)
			},
		)
	}

	## A shell or task under `guix time-machine` at the locked channels.
	steps : Ir, Request, Str, List(Pin) -> Try(Steps, Str)
	steps = |ir, request, generated, locked| {
		shell = GuixBackend.plan(ir, request)?
		what = match request {
			Request.Shell(name, _) => "shell ${name}"
			Request.Run(name, _) => "task ${name}"
			_ => "guix"
		}
		channels = "${generated}/guix/channels.scm"
		entries = locked.map(|p| { channel: p.channel, commit: Pinned(p.commit) })
		argv = ["guix", "time-machine", "-q", "-C", channels, "--"].concat(shell)
		Ok(
			Steps.{
				steps: [
					Write([{ path: channels, contents: GuixBackend.channels_scm(entries) }]),
					Run({ what, argv, output: Inherit }),
				],
				next: Done,
			},
		)
	}
}

fixture : List(Ir.Environment) -> Ir
fixture = |environments| {
	..Ir.empty("guix tests"),
	systems: ["x86_64-linux"],
	sources: [
		{ name: "nix", provider: NixPackages("github:NixOS/nixpkgs") },
		{ name: "guix", provider: GuixPackages("channels") },
	],
	inputs: [{ name: "patch", url: "github:example/patch", kind: Overlay }],
	environments,
	shells: environments.map(|e| { name: e.name, environment: e.name }),
}

env : Str, List(Str) -> Ir.Environment
env = |name, tools| {
	name,
	parents: [],
	tools: tools.map(|text| Project.tool(text) ?? { source: "", name: text }),
	overlays: [],
}

check : List(Ir.Environment), Request, Try(List(Str), {}) -> Bool
check = |environments, request, expected|
	match (GuixBackend.plan(fixture(environments), request), expected) {
		(Ok(argv), Ok(want)) => argv == want
		(Err(_), Err({})) => Bool.True
		_ => Bool.False
	}

# Inherited and named-source tools are native specifications, passed as
# exact argv; a command follows --, arguments unchanged.
expect [
	(
		Request.Shell("dev", []),
		Ok(["shell", "-q", "--pure", "git", "hello@2.12:out"]),
	),
	(
		Request.Shell("dev", ["hello", "--greeting", "two words", ""]),
		Ok([
			"shell",
			"-q",
			"--pure",
			"git",
			"hello@2.12:out",
			"--",
			"hello",
			"--greeting",
			"two words",
			"",
		]),
	),
].all(
	|(request, expected)|
		check(
			[
				env("base", ["git"]),
				{ ..env("dev", ["guix#hello@2.12:out"]), parents: ["base"] },
			],
			request,
			expected,
		),
)

# Nix-only data, empty tool lists and builds or workflows are refused.
expect [
	([env("dev", ["nix#hello"])], Request.Shell("dev", [])),
	([env("dev", ["python3Packages.requests'"])], Request.Shell("dev", [])),
	([{ ..env("dev", ["hello"]), overlays: ["patch"] }], Request.Shell("dev", [])),
	([env("dev", [])], Request.Shell("dev", [])),
	([env("dev", ["-L"])], Request.Shell("dev", [])),
	([env("dev", ["hello"])], Request.Shell("missing", [])),
	([env("dev", ["hello"])], Request.Build("dev")),
	([env("dev", ["hello"])], Request.Workflow("dev")),
	([env("dev", ["hello"])], Request.Generate),
].all(|(environments, request)| check(environments, request, Err({})))

hex = "0123456789abcdef0123456789abcdef01234567"

# A pinned channels file is the default channel with its locked commit.
expect
	GuixBackend.channels_scm(
		[{ channel: GuixBackend.default_channel, commit: Pinned(hex) }],
	)
		==
		\\(list (channel
		\\        (name 'guix)
		\\        (url "https://git.guix.gnu.org/guix.git")
		\\        (branch "master")
		\\        (commit "0123456789abcdef0123456789abcdef01234567")
		\\        (introduction
		\\         (make-channel-introduction
		\\          "9edb3f66fd807b096b48283debdcddccfea34bad"
		\\          (openpgp-fingerprint
		\\           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
		\\

# The lock script's result pins every channel with a 40-hex commit; the
# section reads back the same pins and refuses a changed channel.
expect {
	channels = [GuixBackend.default_channel]
	result = "{\"channels\":[{\"name\":\"guix\",\"commit\":\"${hex}\"}]}"
	pins = GuixBackend.pins(channels, result)
	moved = { ..GuixBackend.default_channel, branch: "main" }
	back = pins.map_ok(|p| GuixBackend.pinned(channels, GuixBackend.section(p)))
	pins == Ok([{ channel: GuixBackend.default_channel, commit: hex }])
		and back == Ok(pins)
			and GuixBackend.pins(channels, result.replace_each(hex, "HEAD")).is_err()
				and pins.map_ok(|p| GuixBackend.pinned([moved], GuixBackend.section(p)))
					.map_ok(|r| r.is_err())
					== Ok(Bool.True)
}

# A shell runs under time-machine at the locked channels, exact argv.
expect {
	ir = fixture([env("dev", ["hello"])])
	pin = { channel: GuixBackend.default_channel, commit: hex }
	shell = Request.Shell("dev", ["hello", "a b"])
	planned = GuixBackend.steps(ir, shell, "/p/.kai/generated", [pin])
	channels = "/p/.kai/generated/guix/channels.scm"
	match planned {
		Ok(plan) =>
			match plan.steps {
				[Write([{ path, .. }]), Run({ argv, what, .. })] =>
					path == channels
						and what == "shell dev"
							and argv == ["guix", "time-machine", "-q", "-C", channels, "--"]
								.concat(["shell", "-q", "--pure", "hello", "--", "hello", "a b"])
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
}
