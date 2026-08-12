app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn.tar.zst",
	kai: "../../xkai-bin/package.roc",
	parser: "../../xkai-bin/parser/main.roc",
}

import parser.Body
import kai.Plugin as PluginApi

import CustomPlugin

main! = |_| Ok({})

# Parsed input: message: "rendered from validated config"
# Ignored raw config block: message: ["not the renderer input"]
# Expected output text: "rendered from validated config"
expect {
	config = Body.parse(
		CustomPlugin.custom_body,
		"message: \"rendered from validated config\"",
	)?
	# FIX: what is rendercontext?
	context = PluginApi.RenderContext.{
		args: [],
		config,
		host_arch: X64,
		host_os: LINUX,
		related_config: NoRelatedConfig,
		# FIX: what is SelectedConfigBlock and where is that def coming from?
		config_block: SelectedConfigBlock({
			body: "message: [\"not the renderer input\"]",
			# FIX: whats byte_offset?
			location: {
				byte_offset: 0,
				column: 1,
				line: 1,
			},
		}),
	}
	# FIX: what is .render do?
	CustomPlugin.render(context) == Ok(
		# FIX: what is renderresult?
		PluginApi.RenderResult.{
			actions: [],
			outputs: [
				{
					name: "message",
					text: "rendered from validated config",
				},
			],
			requested_packages: [],
		},
	)
}

# Input: message: [] -> WrongType(String, "message")
expect {
	match Body.parse(CustomPlugin.custom_body, "message: []") {
		Err(
			{
				byte_offset: _,
				kind: WrongType(
					{
						expected: String,
						field: "message",
					},
				),
			},
		) => Bool.True
		_ => Bool.False
	}
}
