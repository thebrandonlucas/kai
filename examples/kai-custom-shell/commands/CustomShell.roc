import kai.Kai
import kai.Command

CustomShell := [].{
	implementation : _ -> Command.Implementation
	implementation = |project| {
		command: "shell",
		contract: "kai.shell.v1",
		id: "example.shell.composed.nix",
		backends: [Command.Backend.Nix],
		handler: |request| {
			base = Kai.config({
				name: project.name,
				shell: project.shell,
			})
			default = Kai.default_nix_shell(base)
			default_handler = default.handler
			plan = default_handler(request)?

			Ok({
				files: plan.files,
				argv: plan.argv.append("--impure"),
			})
		},
	}
}
