app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "../../xkai-bin/package.roc",
}

import kai.Body
import kai.Plugin as PluginApi

import CustomPlugin

main! = |_| Ok({})

expect {
	config = Body.parse(CustomPlugin.custom_body, "message: \"rendered from validated config\"")?
	context = PluginApi.RenderContext.{
		args: [],
		config,
		host_arch: X64,
		host_os: LINUX,
		source: SelectedSource({
			body: "message: [\"not the renderer input\"]",
			location: { byte_offset: 0, column: 1, line: 1 },
		}),
	}
	CustomPlugin.render(context) == Ok(
		PluginApi.RenderResult.{
			outputs: [{ name: "message", text: "rendered from validated config" }],
			requested_packages: [],
		},
	)
}

expect {
	match Body.parse(CustomPlugin.custom_body, "message: []") {
		Err({ byte_offset: _, kind: WrongType({ expected: String, field: "message" }) }) => Bool.True
		_ => Bool.False
	}
}
