import pf.OsStr
import pf.Stdout

import kai.Plugin as PluginApi

StdPlugin := [].{

	run! = |_args| {
		Stdout.line!("running std plugin")
	}

	plugin : PluginApi.Plugin(OsStr, [StdoutErr(_), ..])
	plugin = PluginApi.Plugin.{
		name: "std-plugin",
		commands: [],
		backends: [],
		implementations: [],
		validator: |_| {},
		run!,
	}
}
