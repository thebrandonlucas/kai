import kai.Plugin as PluginApi
import backends.Local
import commands.Write

WriteLocal := [].{
	render : PluginApi.Renderer
	render = |_| Ok(PluginApi.RenderResult.{ outputs: [], requested_packages: [] })

	implementation : PluginApi.Implementation
	implementation = PluginApi.Implementation.{
		actions: [],
		backend: Local.backend.name,
		command: Write.command.name,
		renderer: WriteLocal.render,
	}
}
