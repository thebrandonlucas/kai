# --pure` argv under `guix time-machine`, at the channels Kai's lock pins.
import api.Layout
import api.LockJson
import api.Plan as Steps
import model.Model
import model.Project
import model.Request

## Tool names are native Guix specifications, never translated from Nix
## names. Every Guix command runs under `guix time-machine` at the channel
## commits Kai's lock pins.
GuixBackend :: [].{

	## Guix runs only on Linux, so refuse other hosts before planning.
	check_system : Str -> Try({}, Str)
	check_system = |system|
		if (system.ends_with("-linux")) Ok({}) else Err("Guix runs only on Linux")

	## Guix plans for the host, whose `system` its environments give their
	## shells, tasks and builds as KAI_SYSTEM. It goes under the Env of
	## environments extending none, so the ones that set it keep theirs.
	with_system : Model, Str -> Model
	with_system = |model, system| {
		variable = { name: "KAI_SYSTEM", value: system }
		stamp = |environment|
			if environment.parents.is_empty()
				and !environment.package_env.any(|v| v.name == variable.name) {
				{ ..environment, env: Project.merge_env([variable], environment.env) }
			} else {
				environment
			}
		{ ..model, environments: model.environments.map(stamp) }
	}

	## `guix shell` arguments for a shell or task, run under time-machine, and
	## the variables it keeps from kai's environment, KAI_ARTIFACTS under
	## `workspace` for a task with Needs.
	Planned : { args : List(Str), env : List(Model.Variable) }

	plan : Model, Request, Str -> Try(Planned, Str)
	plan = |model, request, workspace| {
		project = Project.validate(model)?
		(env_name, command, own_env, received) = match request {
			Request.Shell(name, argv) => {
				shell = project.shells.find_first(|s| s.name == name)
					.map_err(|_| "unknown shell: ${name}")?
				(shell.environment, argv, [], [])
			}
			Request.Run(name, extra) => {
				task = project.tasks.find_first(|t| t.name == name)
					.map_err(|_| "unknown task: ${name}")?
				(
					task.environment,
					task.run.concat(extra),
					task.env.concat(Project.artifacts_variable(task, workspace)),
					task.secrets.concat(task.optional_environment_variables),
				)
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
		tail = if (command.is_empty()) [] else ["--"].concat(command)
		env = Project.merge_env(environment.env, own_env)
		# --pure would drop the operator's shell, which kai passes to children,
		# the variables the environment and task set, and the secrets and optional
		# variables the task declares. Every Guix shell is pure, so Pure
		# environments are no different.
		preserve = ["--preserve=^KAI_OPERATOR_SHELL$"]
			.concat(env.map(|v| "--preserve=^${v.name}$"))
			.concat(received.map(|name| "--preserve=^${name}$"))
		args = ["shell", "-q", "--pure"].concat(preserve).concat(specs).concat(tail)
		Ok({ args, env })
	}

	## A Guix channel as kai pins it: its commit is locked by `kai update`.
	Channel : Model.GuixChannel

	Pin : { channel : Channel, commit : Str }

	## Guix's own channel, then those the project declares.
	project_channels : Model -> List(Channel)
	project_channels = |model|
		[GuixBackend.default_channel].concat(model.guix_channels)

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

	## Run with `guix repl -q -- lock.scm RESULT CHANNELS [NAME PATH]...`:
	## resolves each channel's branch head, authenticated by its introduction,
	## hashes each source tree, and writes the pins as JSON.
	lock_script : Str
	lock_script =
		\\;; kai's Guix lock script: resolve each channel's branch head,
		\\;; authenticated by its introduction, hash each source tree as
		\\;; `guix hash -S nar` does, and write the pins as JSON.
		\\(use-modules (guix channels)
		\\             (guix store)
		\\             (guix openpgp)
		\\             (guix hash)
		\\             (guix base32)
		\\             (json)
		\\             (ice-9 match))
		\\
		\\(define (hashes sources)
		\\  (match sources
		\\    ((name path . rest)
		\\     (cons `((name . ,name)
		\\             (hash . ,(bytevector->nix-base32-string
		\\                       (file-hash* path #:recursive? #t))))
		\\           (hashes rest)))
		\\    (() '())))
		\\
		\\(match (command-line)
		\\  ((_ result unpinned . sources)
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
		\\         (scm->json `((channels . ,(list->vector pins))
		\\                      (sources . ,(list->vector (hashes sources))))
		\\                    port))))))
		\\

	## Run with `guix repl -q -- out-link.scm PATH` before `guix build
	## --root=PATH`, which never replaces a link: removes PATH if it is a link
	## into the store, as an earlier build leaves it, and refuses anything else.
	out_link_script : Str
	out_link_script =
		\\(use-modules (guix store) (ice-9 match))
		\\
		\\(match (command-line)
		\\  ((_ path)
		\\   (let ((status (false-if-exception (lstat path))))
		\\     (when status
		\\       (if (and (eq? (stat:type status) 'symlink)
		\\                (string-prefix? (string-append (%store-prefix) "/")
		\\                                (readlink path)))
		\\           (delete-file path)
		\\           (begin
		\\             (format (current-error-port)
		\\                     "~a is not a link into ~a; not replacing it~%"
		\\                     path (%store-prefix))
		\\             (exit 1)))))))
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

	## A `path:` source: a project-relative tree, locked by its nar hash.
	Tree : { name : Str, path : Str }
	Hashed : { name : Str, path : Str, hash : Str }
	Locked : { channels : List(Pin), sources : List(Hashed) }

	## The tree of `path:` source `name`; Guix cannot fetch other sources yet.
	source_tree : Model, Str -> Try(Tree, Str)
	source_tree = |model, name| {
		if model.fetches.any(|f| f.name == name) {
			return Err("Guix builds cannot read Fetch ${name}; use Nix")
		}
		if model.cargo_vendors.any(|c| c.name == name) {
			return Err("Guix builds cannot read CargoVendor ${name}; use Nix")
		}
		source = model.build_sources.find_first(|s| s.name == name)
			.map_err(|_| "unknown build source: ${name}")?
		if !source.ref.starts_with("path:") {
			return Err("Guix builds take only path: sources: ${name}")
		}
		Ok({ name, path: source.ref.drop_prefix("path:").drop_prefix("./") })
	}

	source_trees : Model -> List(Tree)
	source_trees = |model|
		model.build_sources.keep_oks(|s| GuixBackend.source_tree(model, s.name))

	## The lock script's hash for each tree asked for.
	hashes : List(Tree), Str -> Try(List(Hashed), Str)
	hashes = |wanted, text| {
		found = LockJson.array(LockJson.field(LockJson.decode(text)?, "sources")?)?
		wanted.map_try(
			|{ name, path }| {
				entry = found.find_first(
					|e| (LockJson.field(e, "name") ?? Null) == String(name),
				)
					.map_err(|_| "Guix hashed no ${name} source")?
				hash = LockJson.string(LockJson.field(entry, "hash")?)?
				if (hash.is_empty()) Err("Guix hashed no ${name} source")
				else Ok({ name, path, hash })
			},
		)
	}

	## The lock's guix section: the channel names (its identity), pins and
	## source hashes.
	section : List(Pin), List(Hashed) -> LockJson
	section = |pinned, hashed|
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
									value: GuixBackend.introduction_json(p.channel),
								},
							]),
					),
				),
			},
			{
				name: "sources",
				value: Array(
					hashed.map(
						|h|
							Object([
								{ name: "name", value: String(h.name) },
								{ name: "path", value: String(h.path) },
								{ name: "hash", value: String(h.hash) },
							]),
					),
				),
			},
		])

	introduction_json : Channel -> LockJson
	introduction_json = |{ introduction, .. }|
		Object([
			{ name: "commit", value: String(introduction.commit) },
			{ name: "signer", value: String(introduction.signer) },
		])

	stale_lock = "the guix lock is missing or stale; run kai --backend guix update"

	## The pins of `channels` and the source hashes a guix section holds.
	read_lock : List(Channel), LockJson -> Try(Locked, Str)
	read_lock = |channels, found| {
		entries = match LockJson.field(found, "sources") {
			Ok(sources) => LockJson.array(sources)?
			Err(_) => []
		}
		at = |entry, name| LockJson.string(LockJson.field(entry, name)?)
		sources = entries.map_try(
			|e| Ok({ name: at(e, "name")?, path: at(e, "path")?, hash: at(e, "hash")? }),
		)?
		pinned = GuixBackend.pinned(channels, found)?
		Ok({ channels: pinned, sources })
	}

	## The pins a guix section holds for `channels`, or why it is missing
	## or stale.
	pinned : List(Channel), LockJson -> Try(List(Pin), Str)
	pinned = |channels, found| {
		stale = GuixBackend.stale_lock
		entries = LockJson.array(LockJson.field(found, "channels")?)?
		# A channel no longer declared would otherwise stay in the lock.
		if entries.len() != channels.len() {
			return Err(stale)
		}
		channels.map_try(
			|channel| {
				entry = entries.find_first(
					|e| (LockJson.field(e, "name") ?? Null) == String(channel.name),
				)
					.map_err(|_| stale)?
				same = |name, value| LockJson.field(entry, name) == Ok(String(value))
				introduction = LockJson.field(entry, "introduction")
				if !same("url", channel.url) or !same("branch", channel.branch)
					or introduction != Ok(GuixBackend.introduction_json(channel)) {
					return Err(stale)
				}
				commit = LockJson.string(LockJson.field(entry, "commit")?)?
				if (GuixBackend.hex40(commit)) Ok({ channel, commit }) else Err(stale)
			},
		)
	}

	## A build, or the artifacts of a task's Needs.
	Built : [Build(Str), Artifacts(List(Str))]

	## The Guix build file for `target` and the builds it needs: each runs
	## kai's runner on the project snapshot, as the Nix builds do.
	build_scm : Model, Built, Str, Str -> Try(Str, Str)
	build_scm = |model, target, root, workspace| {
		project = Project.validate(model)?
		q = GuixBackend.quote
		farm = |name, needs| {
			entries = needs.map(|n| "(${q(n)} ,kai-build-${n})")
			"(file-union ${q(name)} `(${Str.join_with(entries, " ")}))"
		}
		(names, result) = match target {
			Build(name) => ([name], "kai-build-${name}")
			Artifacts(needs) => (needs, farm("kai-artifacts", needs))
		}
		var $defines = []
		for build in Project.builds_closure(project, names)? {
			Project.check_environment(project, Guix, build.environment)?
			environment = project.environments
				.find_first(|e| e.name == build.environment)
				.map_err(|_| "unknown environment: ${build.environment}")?
			specs = Str.join_with(environment.tools.map(|t| q(t.name)), " ")
			argv = LockJson.encode(Array(build.run.map(|a| String(a))))
			variables = Project.merge_env(environment.env, build.env)
			env = LockJson.encode(
				Object(variables.map(|v| { name: v.name, value: String(v.value) })),
			)
			project_file = match build.files {
				All => "project"
				Only(paths) =>
					"(local-file ${q("${workspace}/snapshot")} \"kai-project\" "
						.concat("#:recursive? #t #:select? (kai-files ")
						.concat("${q("${workspace}/snapshot/")} ")
						.concat("'(${Str.join_with(paths.map(q), " ")})))")
			}
			# Each locked tree is read where `kai update` hashed it.
			sources = build.inputs.map_try(|n| GuixBackend.source_tree(project, n))?.map(
				|t|
					"(${q(t.name)} ,(local-file ${q("${root}/${t.path}")} "
						.concat("${q("kai-source-${t.name}")} #:recursive? #t))"),
			)
			inputs = "(file-union ${q("kai-inputs-${build.name}")} "
				.concat("`(${Str.join_with(sources, " ")}))")
			artifacts = farm("kai-artifacts-${build.name}", build.needs)
			$defines = $defines.append(
				"(define kai-build-${build.name}\n"
					.concat("  (kai-build ${q(build.name)} '(${specs})\n")
					.concat("    ${project_file} ${q(argv)} ${q(env)}\n")
					.concat("    ${q(build.output)} ${inputs} ${artifacts}))"),
			)
		}
		file = |variable, path, label, recursive|
			"(define ${variable} (local-file ${q(path)} ${q(label)}${recursive}))\n"
		tree = " #:recursive? #t"
		files = file("runner", "${workspace}/build-runner", "kai-build-runner", tree)
			.concat(file("project", "${workspace}/snapshot", "kai-project", tree))
			.concat(
				file(
					"isolation",
					"${workspace}/snapshot.isolation.json",
					"kai-isolation.json",
					"",
				),
			)
		header = "(use-modules (srfi srfi-1) (guix) (guix gexp) (guix profiles)"
			.concat(" (gnu))\n\n")
		Ok(
			header
				.concat(files)
				.concat(GuixBackend.build_procedure)
				.concat(Str.join_with($defines, "\n"))
				.concat("\n${result}\n"),
		)
	}

	## Writes the runner's spec.json (as the Nix builds' kaiSpec) and runs it.
	build_procedure =
		\\
		\\(define (tools specs)
		\\  (profile (content (specifications->manifest
		\\                     (append specs '("coreutils" "bash"))))))
		\\
		\\;; Keeps a selected path, what lies inside it and the directories above it.
		\\(define (kai-files root paths)
		\\  (lambda (file stat)
		\\    (let ((r (if (string-prefix? root file)
		\\                 (substring file (string-length root))
		\\                 "")))
		\\      (or (string-null? r)
		\\          (any (lambda (s)
		\\                 (or (string=? r s)
		\\                     (string-prefix? (string-append s "/") r)
		\\                     (string-prefix? (string-append r "/") s)))
		\\               paths)))))
		\\
		\\(define (kai-build name specs project argv-json env-json output-dir inputs
		\\                   artifacts)
		\\  (computed-file (string-append "kai-" name)
		\\    #~(begin
		\\        (use-modules (ice-9 textual-ports))
		\\        (let ((witness (call-with-input-file #$isolation get-string-all)))
		\\          (call-with-output-file "spec.json"
		\\            (lambda (port)
		\\              (display
		\\               (string-append
		\\                "{\\"project\\":\\"" #$project "\\""
		\\                ",\\"isolation\\":" witness
		\\                ",\\"argv\\":" #$argv-json
		\\                ",\\"env\\":" #$env-json
		\\                ",\\"output\\":\\"" #$output-dir "\\""
		\\                ",\\"path\\":\\"" #$(tools specs) "/bin\\""
		\\                ",\\"coreutils\\":\\""
		\\                #$(specification->package "coreutils") "/bin\\""
		\\                ",\\"inputs\\":\\"" #$inputs "\\""
		\\                ",\\"artifacts\\":\\"" #$artifacts "\\"}")
		\\               port))))
		\\        (setenv "out" #$output)
		\\        (execl #$runner "kai-build-runner" "__build-runner" "spec.json"))))
		\\
		\\

	## A build under time-machine: kai snapshots the project and installs
	## its runner, then Guix builds the file above; the artifact is the store
	## path `guix build` prints.
	build_steps :
		Model, Str, Request.BuildOutput, Layout, Locked -> Try(Steps, Str)
	build_steps = |model, name, shown, layout, locked| {
		build = model.builds.find_first(|b| b.name == name)
			.map_err(|_| "unknown build: ${name}")?
		# `guix build --root` never replaces a link, so the link an earlier
		# build left is removed first; anything else at the path is refused.
		replace_out_link = match shown.out_link {
			Ok(path) => {
				script = "${layout.generated_root}/guix/out-link.scm"
				[
					Write([{ path: script, contents: GuixBackend.out_link_script }]),
					Run({
						description: "replace out-link ${path}",
						argv: ["guix", "repl", "-q", "--", script, path],
						output: Quiet,
						secrets: [],
						removed_environment_variables: [],
						kept_environment_variables: [],
					}),
				]
			}
			Err(_) => []
		}
		GuixBackend.sandboxed_steps(
			model,
			Build(name),
			"build-${name}.scm",
			layout,
			locked,
			replace_out_link,
			|argv|
				Run({
					description: "build ${name}",
					argv: argv
						.concat(if (shown.print_build_logs) ["--verbosity=3"] else [])
						.concat(shown.out_link.map_ok(|path| ["--root=${path}"]) ?? []),
					output: Artifact(
						{ name, label: "build-${name}.scm", output: build.output },
					),
					secrets: [],
					removed_environment_variables: [],
					kept_environment_variables: [],
				}),
		)
	}

	## The Run step that builds with the given argv.
	Builder : List(Str) -> Steps.Step

	## Steps that run before the snapshot, such as replacing an out-link.
	Before : List(Steps.Step)

	## Builds `target` from `file` with the argv `run` completes, after the
	## `before` steps. Each source tree it reads must still have its locked
	## hash, and stays out of the snapshot, as on Nix.
	sandboxed_steps :
		Model, Built, Str, Layout, Locked, Before, Builder -> Try(Steps, Str)
	sandboxed_steps = |model, target, file, layout, locked, before, run| {
		root = layout.project_root
		workspace = layout.workspace
		dir = "${layout.generated_root}/guix"
		channels = "${dir}/channels.scm"
		scm = "${dir}/${file}"
		entries = locked.channels.map(
			|p| { channel: p.channel, commit: Pinned(p.commit) },
		)
		names = match target {
			Build(name) => [name]
			Artifacts(needs) => needs
		}
		closure = Project.builds_closure(model, names)?
		var $checks = []
		for needed in closure {
			for input in needed.inputs {
				{ path, .. } = GuixBackend.source_tree(model, input)?
				hashed = locked.sources.find_first(|h| h.name == input and h.path == path)
					.map_err(|_| GuixBackend.stale_lock)?
				full = "${root}/${path}"
				check = VerifyPath({
					path: full,
					argv: ["guix", "hash", "-S", "nar", full],
					stdout: hashed.hash,
					update: "kai --backend guix update",
				})
				if !$checks.contains(check) {
					$checks = $checks.append(check)
				}
			}
		}
		exclude = [".git", ".hg", ".svn", ".jj"]
			.concat([workspace, layout.generated_root, layout.lock_path])
			.concat(GuixBackend.source_trees(model).map(|t| "${root}/${t.path}"))
		Ok(
			Steps.{
				steps: $checks.concat(before).concat([
					Snapshot({
						root: Project.snapshot_root(model, root)?,
						destination: "${workspace}/snapshot",
						exclude,
						files: Project.snapshot_files(closure),
						store: "/gnu/store",
					}),
					InstallRunner({ destination: "${workspace}/build-runner" }),
					Write([
						{ path: channels, contents: GuixBackend.channels_scm(entries) },
						{
							path: scm,
							contents: GuixBackend.build_scm(model, target, root, workspace)?,
						},
					]),
					run(["guix", "time-machine", "-C", channels, "--", "build", "-f", scm]),
				]),
				next: Done,
			},
		)
	}

	## A shell, or a task after the builds it needs, as `kai build` builds
	## them, into the directory its KAI_ARTIFACTS names.
	task_steps : Model, Request, Layout, Locked -> Try(Steps, Str)
	task_steps = |model, request, layout, locked| {
		needs = match request {
			Request.Run(name, _) =>
				match model.tasks.find_first(|t| t.name == name) {
					Ok(task) =>
						Project.artifacts_variable(task, layout.workspace).map_try(
							|variable| {
								link = variable.value
								# `guix build --root` never replaces an existing link.
								unlink = Run({
									description: "remove ${link}",
									argv: ["rm", "-f", link],
									output: Quiet,
									secrets: [],
									removed_environment_variables: [],
									kept_environment_variables: [],
								})
								built = GuixBackend.sandboxed_steps(
									model,
									Artifacts(task.needs),
									"artifacts-${name}.scm",
									layout,
									locked,
									[],
									|argv|
										Run({
											description: "build needs of task ${name}",
											argv: argv.append("--root=${link}"),
											output: Artifact({
												name: "artifacts-${name}",
												label: "artifacts-${name}.scm",
												output: Str.join_with(task.needs, ", "),
											}),
											secrets: [],
											removed_environment_variables: [],
											kept_environment_variables: [],
										}),
								)?
								Ok([unlink].concat(built.steps))
							},
						)?
					Err(_) => []
				}
			_ => []
		}
		shell = GuixBackend.steps(model, request, layout, locked.channels)?
		steps = needs.join_map(|built| built).concat(shell.steps)
		Ok(Steps.{ steps, next: Done })
	}

	## The steps for any request Guix serves; a workflow's steps are marked
	## with Stages, as on Nix.
	request_steps : Model, Request, Layout, Locked -> Try(Steps, Str)
	request_steps = |model, request, layout, locked|
		match request {
			Request.Build(name, shown) =>
				GuixBackend.build_steps(model, name, shown, layout, locked)
			Request.Workflow(name) => {
				var $steps = []
				for step in Project.workflow_steps(model, name)? {
					$steps = match step {
						RunTask(task, args) => {
							part = GuixBackend.task_steps(
								model,
								Request.Run(task, args),
								layout,
								locked,
							)?
							$steps.append(Stage("run ${task}")).concat(part.steps)
						}
						BuildArtifact(build) => {
							quiet = Request.default_output
							part = GuixBackend.build_steps(model, build, quiet, layout, locked)?
							$steps.append(Stage("build ${build}")).concat(part.steps)
						}
						MayFail(count) => $steps.append(MayFail(count))
					}
				}
				Ok(Steps.{ steps: $steps, next: Done })
			}
			_ => GuixBackend.task_steps(model, request, layout, locked)
		}

	## Whether Guix can serve a request: shells and tasks by their
	## environment, builds by their closure, workflows by every step.
	fit : Model, Request -> Try({}, Str)
	fit = |model, request|
		match request {
			Request.Build(name, _) =>
				GuixBackend.build_scm(model, Build(name), "/fit", "/fit").map_ok(|_| {})
			Request.Workflow(name) => {
				for step in Project.workflow_steps(model, name)? {
					match step {
						RunTask(task, args) => GuixBackend.fit(model, Request.Run(task, args))?
						BuildArtifact(build) => GuixBackend.fit(model, Request.build(build))?
						MayFail(_) => {}
					}
				}
				Ok({})
			}
			Request.Run(name, _) => {
				_ = GuixBackend.plan(model, request, "/fit")?
				task = model.tasks.find_first(|t| t.name == name)
				needs = task.map_ok(|t| t.needs) ?? []
				if (needs.is_empty()) Ok({})
				else GuixBackend.build_scm(model, Artifacts(needs), "/fit", "/fit")
					.map_ok(|_| {})
			}
			_ => GuixBackend.plan(model, request, "/fit").map_ok(|_| {})
		}

	## A shell or task under `guix time-machine` at the locked channels.
	steps : Model, Request, Layout, List(Pin) -> Try(Steps, Str)
	steps = |model, request, layout, locked| {
		shell = GuixBackend.plan(model, request, layout.workspace)?
		description = match request {
			Request.Shell(name, _) => "shell ${name}"
			Request.Run(name, _) => "task ${name}"
			_ => "guix"
		}
		(
			secrets,
			removed_environment_variables,
			kept_environment_variables,
			dir,
		) = match request {
			Request.Run(name, _) =>
				match model.tasks.find_first(|t| t.name == name) {
					Ok(task) => {
						removed = Project.other_tasks_secrets(model, task)
						(
							task.secrets,
							removed,
							task.optional_environment_variables,
							task.dir,
						)
					}
					Err(_) => ([], [], [], "")
				}
			_ => ([], [], [], "")
		}
		channels = "${layout.generated_root}/guix/channels.scm"
		entries = locked.map(|p| { channel: p.channel, commit: Pinned(p.commit) })
		# --pure keeps only what --preserve names, so kai sets it on guix, which
		# runs the task in its directory.
		argv = Project.env_command(dir, shell.env)
			.concat(["guix", "time-machine", "-C", channels, "--"])
			.concat(shell.args)
		Ok(
			Steps.{
				steps: [
					Write([{ path: channels, contents: GuixBackend.channels_scm(entries) }]),
					Run({
						description,
						argv,
						output: Inherit,
						secrets,
						removed_environment_variables,
						kept_environment_variables,
					}),
				],
				next: Done,
			},
		)
	}
}

fixture : List(Model.Environment) -> Model
fixture = |environments| {
	..Model.empty("guix tests"),
	systems: ["x86_64-linux"],
	sources: [
		{ name: "nix", provider: NixPackages("github:NixOS/nixpkgs") },
		{ name: "guix", provider: GuixPackages("channels") },
	],
	inputs: [{ name: "patch", url: "github:example/patch", kind: Overlay }],
	environments,
	shells: environments.map(
		|e| {
			name: e.name,
			environment: e.name,
			description: "",
		},
	),
}

env : Str, List(Str) -> Model.Environment
env = |name, tools| {
	name,
	parents: [],
	tools: tools.map(|text| Project.tool(text) ?? { source: "", name: text }),
	overlays: [],
	env: [],
	pure: Bool.False,
	aliases: [],
	rust_toolchain: None,
	package_env: [],
	on_systems: [],
}

check : List(Model.Environment), Request, Try(List(Str), {}) -> Bool
check = |environments, request, expected|
	match (GuixBackend.plan(fixture(environments), request, "/p/.kai"), expected) {
		(Ok(planned), Ok(want)) => planned.args == want
		(Err(_), Err({})) => Bool.True
		_ => Bool.False
	}

# Inherited and named-source tools are native specifications, passed as
# exact argv; a command follows --, arguments unchanged.
expect [
	(
		Request.Shell("dev", []),
		Ok(
			["shell", "-q", "--pure", "--preserve=^KAI_OPERATOR_SHELL$"]
				.concat(["git", "hello@2.12:out"]),
		),
	),
	(
		Request.Shell("dev", ["hello", "--greeting", "two words", ""]),
		Ok([
			"shell",
			"-q",
			"--pure",
			"--preserve=^KAI_OPERATOR_SHELL$",
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
	([env("dev", ["hello"])], Request.build("dev")),
	([env("dev", ["hello"])], Request.Workflow("dev")),
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
	section = |p| GuixBackend.section(p, [])
	back = pins.map_ok(|p| GuixBackend.pinned(channels, section(p)))
	pins == Ok([{ channel: GuixBackend.default_channel, commit: hex }])
		and back == Ok(pins)
		and GuixBackend.pins(channels, result.replace_each(hex, "HEAD")).is_err()
		and pins.map_ok(|p| GuixBackend.pinned([moved], section(p)))
			.map_ok(|r| r.is_err())
			== Ok(Bool.True)
}

# A shell runs under time-machine at the locked channels, exact argv.
expect {
	model = fixture([env("dev", ["hello"])])
	pin = { channel: GuixBackend.default_channel, commit: hex }
	shell = Request.Shell("dev", ["hello", "a b"])
	layout = Layout.{
		project_root: "/p",
		workspace: "/p/.kai",
		generated_root: "/p/.kai/generated",
		lock_path: "/p/.kai/lock.json",
	}
	planned = GuixBackend.steps(model, shell, layout, [pin])
	channels = "/p/.kai/generated/guix/channels.scm"
	match planned {
		Ok(plan) =>
			match plan.steps {
				[Write([{ path, .. }]), Run({ argv, description, .. })] =>
					path == channels
						and description == "shell dev"
						and argv == ["guix", "time-machine", "-C", channels, "--"]
							.concat(["shell", "-q", "--pure", "--preserve=^KAI_OPERATOR_SHELL$"])
							.concat(["hello", "--", "hello", "a b"])
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
}

# A build's needs render first and become its artifacts.
expect {
	build = |name, needs, inputs| {
		name,
		environment: "dev",
		inputs,
		needs,
		run: ["true"],
		output: "out",
		files: All,
		description: "",
		env: [],
		revision: Bool.False,
		default: Bool.False,
	}
	model = {
		..fixture([env("dev", ["hello"])]),
		requires_: ["builds"],
		builds: [build("app", ["lib"], []), build("lib", [], [])],
	}
	rendered = GuixBackend.build_scm(model, Build("app"), "/p", "/p/.kai") ?? ""
	lib = rendered.split_on("(define kai-build-lib").len() == 2
	before = rendered.split_on("(define kai-build-app").first() ?? ""
	order = before.contains("kai-build-lib")
	lib
		and order
		and rendered.contains("(\"lib\" ,kai-build-lib)")
		and rendered.ends_with("kai-build-app\n")
		and GuixBackend.build_scm(model, Build("data"), "/p", "/p/.kai").is_err()
}

# KAI_SYSTEM goes under the Env of environments extending none, which those
# extending them inherit.
expect {
	system = { name: "KAI_SYSTEM", value: "x86_64-linux" }
	mine = { name: "KAI_SYSTEM", value: "mine" }
	environments = [
		env("base", ["git"]),
		{ ..env("dev", ["hello"]), parents: ["base"] },
		{ ..env("own", ["git"]), env: [mine] },
	]
	stamped = GuixBackend.with_system(fixture(environments), "x86_64-linux")
	stamped.environments.map(|e| e.env) == [[system], [], [mine]]
}
