# An implementation for updating the underlying `flake.nix` files
import kai.Plugin
import backends.Nix as NixBackend
import commands.Update as UpdateCommand
import project_configs.Nixpkgs
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
		target = NixBackend.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported update platform" }
		nixpkgs = Nixpkgs.select(context, target.system)?
		Ok(
			Plugin.RenderResult.{
				actions: [],
				artifacts: [],
				outputs: [
					{
						name: "flake",
						text: NixBackend.render_update_flake(
							overlays,
							sources,
							nixpkgs,
						),
					},
				],
				requests: [],
				requested_packages: [],
			},
		)
	}
}
