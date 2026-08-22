import kai.Plugin
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
import EnvironmentNix
UpdateNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [NixBackend.flake_template].concat(NixBackend.update_lock_templates),
		backend: NixBackend.backend.name,
		command: UpdateCommand.command.name,
		renderer: UpdateNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		overlays = EnvironmentNix.all_overlays(context)?
		Ok(
			Plugin.RenderResult.{
				actions: [],
				outputs: [{ name: "flake", text: NixBackend.render_update_flake(overlays) }],
				requests: [],
				requested_packages: [],
			},
		)
	}
}
