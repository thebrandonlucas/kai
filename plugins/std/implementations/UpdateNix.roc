# An implementation for updating the underlying `flake.nix` files
import kai.Plugin
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
import EnvironmentNix
UpdateNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [NixBackend.flake_template].concat(NixBackend.update_lock_templates),
		backend: NixBackend.backend.name,
		command: UpdateCommand.command.call.name,
		renderer: UpdateNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		overlays = EnvironmentNix.all_overlays(context)?
		sources = EnvironmentNix.all_sources(context)?
		Ok(
			Plugin.RenderResult.{
				actions: [],
				artifacts: [],
				outputs: [
					{
						name: "flake",
						text: NixBackend.render_update_flake(overlays, sources),
					},
				],
				requests: [],
				requested_packages: [],
			},
		)
	}
}
