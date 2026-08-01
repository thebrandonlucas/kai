import pf.OsStr
import pf.Stdout

import kai.Plugin as PluginApi
import kai.Command
import kai.Backend
import kai.Implementation

StdPlugin := [].{

	run! = |_args| {
		Stdout.line!("running std plugin")
	}

	plugin : PluginApi.Plugin(OsStr, [StdoutErr(_), ..])
	plugin = PluginApi.Plugin.{
		name: "std-plugin",
		commands: [
			shell,
		],
		backends: [],
		implementations: [],
		validator: |_| {},
		run!,
	}
}
