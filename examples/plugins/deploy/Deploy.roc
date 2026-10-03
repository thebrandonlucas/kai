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
						h = Deploy.find(known, Command.name(ctx.args, "host"))?
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
								what: "deploy ${h.name}",
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
