# kai deploy HOST: confirm, then run nixos-rebuild switch for the host's
# flake output on its address, inside a std environment with the tools.
import pf.Command
import pf.Implementation
import pf.Plan
import pf.Plugin
import std.Config
import std.Std

Deploy := [].{
	Setting := [Host(Str, List(HostSetting))]

	HostSetting := [Address(Str), Flake(Str), Tools(Str)]

	Host : { name : Str, address : Str, flake : Str, tools : Str }

	## `project` is std's settings, whose environments the hosts use.
	plugin : List(Config.Setting), List(Setting) -> Plugin
	plugin = |project, settings| {
		hosts = settings.map(Deploy.host)
		problems = hosts.keep_oks(
			|h|
				match h {
					Err(problem) => Ok(problem)
					Ok(_) => Err({})
				},
		)
		if !problems.is_empty() {
			return Plugin.invalid("deploy", problems)
		}
		known = hosts.keep_oks(|h| h)
		Plugin.new({
			name: "deploy",
			version: "0.1.0",
			describe: "",
			commands: [
				Command.{
					name: "deploy",
					summary: Deploy.page.description,
					help: Deploy.page,
					args: [
						Name({
							name: "host",
							help: "The host to deploy.",
							choices: known.map(
								|h| {
									value: h.name,
									summary: "${h.flake} to ${h.address}",
									details: [],
								},
							),
							default: Required,
						}),
					],
					lock: ReadsLock,
				},
			],
			backends: [],
			implementations: [
				Implementation.{
					command: "deploy",
					backend: On("nix"),
					fit: |args| Deploy.find(known, Command.name(args, "host")).map_ok(|_| {}),
					plan: |ctx| {
						h = Deploy.find(known, Command.name(ctx.args, "host")).map_err(Plan.fail)?
						run = Std.run_in(
							project,
							ctx,
							{
								environment: h.tools,
								argv: [
									"nixos-rebuild",
									"switch",
									"--flake",
									h.flake,
									"--target-host",
									h.address,
									"--use-remote-sudo",
								],
								description: "deploy ${h.name}",
							},
						)?
						prompt = "Deploy ${h.flake} to ${h.address} and switch it now?"
						Ok(Plan.{ steps: [Confirm(prompt)].concat(run.steps), next: run.next })
					},
				},
			],
		})
	}

	page : Command.Page
	page = {
		description: "Switch a NixOS host to its flake output with nixos-rebuild.",
		examples: ["kai --dry-run deploy web", "kai --yes deploy web"],
		config: [
			"Host(\"web\", [Address(\"root@203.0.113.7\"), Flake(\".#web\"),"
				.concat(" Tools(\"ops\")]),"),
		],
	}

	host : Setting -> Try(Host, Str)
	host = |setting|
		match setting {
			Host(name, parts) => {
				found = parts.fold(
					{ name, address: "", flake: "", tools: "" },
					|acc, part|
						match part {
							Address(address) => { ..acc, address }
							Flake(flake) => { ..acc, flake }
							Tools(tools) => { ..acc, tools }
						},
				)
				if [found.address, found.flake, found.tools].any(Str.is_empty) {
					Err("host ${name} needs Address, Flake and Tools")
				} else {
					Ok(found)
				}
			}
		}

	find : List(Host), Str -> Try(Host, Str)
	find = |hosts, name|
		hosts.find_first(|h| h.name == name).map_err(|_| "unknown host: ${name}")
}

import pf.Layout

# The flake.lock nix flake update writes for the project's nixpkgs.
flake_lock =
	\\{
	\\  "nodes": {
	\\    "default": {
	\\      "locked": {
	\\        "lastModified": 1790185690,
	\\        "narHash": "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=",
	\\        "owner": "NixOS",
	\\        "repo": "nixpkgs",
	\\        "rev": "4975466d324710c576dc11ad614684e6bd8cad8e",
	\\        "type": "github"
	\\      },
	\\      "original": {
	\\        "owner": "NixOS", "ref": "nixos-unstable",
	\\        "repo": "nixpkgs", "type": "github"
	\\      }
	\\    },
	\\    "root": { "inputs": { "default": "default" } }
	\\  },
	\\  "root": "root",
	\\  "version": 7
	\\}

# std settings with an environment for the tools.
project : List(Config.Setting)
project = [
	Name("ops"),
	Systems(["x86_64-linux"]),
	Environment("ops", [Tools(["nixos-rebuild"])]),
]

context : Implementation.Context
context = {
	args: [],
	backend: "nix",
	host: { system: "x86_64-linux" },
	layout: Layout.{
		project_root: "/project",
		workspace: "/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	},
	revision: { describe: "", commit_date: "" },
	lock: Absent,
	phase: 0,
	observed: [],
}

# The plan `plugin`'s Nix implementation of `command` makes for the context.
planned : Plugin, Str, Implementation.Context -> Try(Plan, Plan.Failure)
planned = |plugin, command, ctx| {
	found = plugin.implementations
		.find_first(|i| i.command == command and i.backend == On("nix"))
		.map_err(|_| Plan.fail("no ${command} on nix"))?
	(found.plan)(ctx)
}

# A deploy confirms, then runs nixos-rebuild switch for the host's flake
# output in the tools environment; an unknown host is refused.
expect {
	observed = [{ path: "/generated/nix/flake.lock", contents: Text(flake_lock) }]
	resumed = { ..context, phase: 1, observed }
	update = planned(Std.plugin(project), "update", resumed)
	lock = match update.map_ok(|plan| plan.steps) {
		Ok([PublishLock({ contents, .. }), ..]) => Present(contents)
		_ => Absent
	}
	host = [Address("root@203.0.113.7"), Flake(".#web"), Tools("ops")]
	plugin = Deploy.plugin(project, [Host("web", host)])
	args = |name| [{ name: "host", value: Present(name) }]
	deploy = |name| { ..context, args: args(name), lock }
	rebuild = [
		"nixos-rebuild",
		"switch",
		"--flake",
		".#web",
		"--target-host",
		"root@203.0.113.7",
		"--use-remote-sudo",
	]
	match planned(plugin, "deploy", deploy("web")).map_ok(|plan| plan.steps) {
		Ok([Confirm(prompt), .., Run({ description, argv, .. })]) =>
			prompt == "Deploy .#web to root@203.0.113.7 and switch it now?"
				and description == "deploy web"
				and argv.ends_with(rebuild)
				and planned(plugin, "deploy", deploy("db"))
					== Err(Plan.fail("unknown host: db"))
		_ => Bool.False
	}
}
