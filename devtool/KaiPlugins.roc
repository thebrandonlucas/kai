# Run a built kai against real Nix on a project whose Kaifile.roc adds the
# example deploy plugin and replaces std's Nix shell with a plugin of its
# own: plugin help, describe, a replaced implementation, a backend without
# an implementation, confirmation refusals and a dry run, and no deploy
# ever runs.
import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout

import ConfigFixtures

KaiPlugins := [].{
	body =
		\\import pf.Implementation
		\\import pf.Kaifile
		\\import pf.Plan
		\\import pf.Plugin
		\\import std.Config
		\\import std.Std
		\\import deploy.Deploy
		\\
		\\project : List(Config.Setting)
		\\project = [
		\\	Name("site"),
		\\	Systems(["x86_64-linux", "aarch64-linux"]),
		\\	Environment("ops", [Tools(["coreutils"])]),
		\\	Shell("default", [Use("ops")]),
		\\]
		\\
		\\quiet = Plugin.new({
		\\	name: "quiet",
		\\	version: "1",
		\\	describe: "",
		\\	commands: [],
		\\	backends: [],
		\\	implementations: [
		\\		Implementation.{
		\\			command: "shell",
		\\			backend: On("nix"),
		\\			fit: |_| Ok({}),
		\\			plan: |_| Ok(Plan.{ steps: [Print("quiet shell")], next: Done }),
		\\		},
		\\	],
		\\})
		\\
		\\web = Host(
		\\	"web",
		\\	[Address("root@203.0.113.7"), Flake(".#web"), Tools("ops")],
		\\)
		\\
		\\kaifile = Kaifile.new([
		\\	Std.plugin(project).without({ command: "shell", backend: "nix" }),
		\\	Deploy.plugin(project, [web]),
		\\	quiet,
		\\])
		\\

	run! = |binary| {
		root = Path.canonicalize!(Env.cwd!()?)?
		kai = Path.canonicalize!(Path.utf8(binary))?
		temporary = Env.create_temp_dir_with_prefix!("kai-plugins-")?
		project = Path.canonicalize!(temporary)?
		result = KaiPlugins.run_in!(root, kai, project)
		Path.delete_all!(project)?
		result
	}

	run_in! = |root, kai, project| {
		deploy = ConfigFixtures.relative(
			Path.display(project),
			Path.display(Path.join(root, "examples/plugins/deploy/main.roc")),
		)
		opened = ConfigFixtures.header(root, project).drop_suffix("}")
		header = "${opened}\tdeploy: \"${deploy}\",\n}"
		Path.write_utf8!(
			Path.join(project, "Kaifile.roc"),
			"${header}\n\n${KaiPlugins.body}",
		)?
		kai! = |args| Cmd.new(Path.to_os_str(kai)).args_str(args).cwd(project)
			.exec_output!()
		failed! = |args, code, text|
			match kai!(args) {
				Err(NonZeroExitCode(out)) => {
					shown = out.stdout_utf8_lossy.concat(out.stderr_utf8_lossy)
					if out.exit_code == code and shown.contains(text) {
						Ok({})
					} else {
						Err(UnexpectedResult(args, shown))
					}
				}
				other => Err(UnexpectedResult(args, Str.inspect(other)))
			}
		help = kai!(["deploy", "--help"])?.stdout_utf8
		if !help.contains("nixos-rebuild") or !help.contains("root@203.0.113.7") {
			return Err(PluginHelpMissing(help))
		}
		described = kai!(["describe"])?.stdout_utf8
		expected = "plugins: std, deploy 0.1.0, quiet 1\n"
			.concat("commands: shell, run, build, workflow, update, model, deploy\n")
			.concat("backends: nix, guix\n")
		if described != expected {
			return Err(WrongDescribe(described))
		}
		shell = kai!(["shell"])?.stdout_utf8
		if shell != "quiet shell\n" {
			return Err(ShellNotReplaced(shell))
		}
		failed!(
			["--backend", "guix", "deploy", "web"],
			1,
			"no plugin implements this command on guix",
		)?
		failed!(["deploy", "nope"], 2, "nope")?
		_ = kai!(["update"])?
		lock = Path.read_bytes!(Path.join(project, ".kai/lock.json"))?
		failed!(["--json", "deploy", "web"], 1, "confirmation_required")?
		failed!(["deploy", "web"], 1, "pass --yes to accept")?
		dry = kai!(["--dry-run", "deploy", "web"])?.stdout_utf8
		if !dry.contains("(Confirm ") or !dry.contains("\"nixos-rebuild\"") {
			return Err(DryRunWithoutPlan(dry))
		}
		if Path.read_bytes!(Path.join(project, ".kai/lock.json"))? != lock {
			return Err(LockChanged)
		}
		Stdout.line!(
			"kai ran plugin commands, replaced a command and refused "
				.concat("unconfirmed deploys"),
		)
	}
}
