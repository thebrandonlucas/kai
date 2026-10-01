# Helps a plugin show that every implementation has planning tests: list
# its implementations and the cases the plugin's tests run, and `missing`
# names the uncovered ones.
import Plugin

Conformance := [].{

	## One planning test: the command and backend ("" for an Independent
	## implementation) it plans on.
	Case : { command : Str, backend : Str }

	## (command, backend) pairs with no case; empty means covered.
	missing : Plugin, List(Case) -> List((Str, Str))
	missing = |plugin, cases|
		plugin.implementations
			.map(
				|i|
					match i.backend {
						On(id) => (i.command, id)
						Independent => (i.command, "")
					},
			)
			.keep_if(
				|(command, backend)|
					!cases.any(|c| c.command == command and c.backend == backend),
			)
}

covered : Plugin
covered = Plugin.new({
	name: "p",
	version: "1",
	describe: "",
	commands: [],
	backends: [],
	implementations: [
		{ command: "a", backend: On("nix"), fit: |_| Ok({}), plan: |_| Err("") },
		{ command: "b", backend: Independent, fit: |_| Ok({}), plan: |_| Err("") },
	],
})

# Implementations without a case are listed; covered ones are not.
expect Conformance.missing(covered, [{ command: "a", backend: "nix" }])
	== [("b", "")]
	and Conformance.missing(
		covered,
		[{ command: "a", backend: "nix" }, { command: "b", backend: "" }],
	)
		== []
