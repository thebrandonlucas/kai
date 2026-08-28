# An implementation for interfacing between Kai environment configuration and
# the Nix backend.
import kai.Plugin
import backends.Nix as NixBackend
import configs.EnvironmentConfig
import project_configs.Source

EnvironmentNix := [].{
	extract_overlays = |config|
		Plugin.validated_strings(config, EnvironmentConfig.overlays_field)

	collect_overlays = |entries, collected|
		match entries {
			[] => Ok(collected)
			[first, .. as rest] => {
				overlays = EnvironmentNix.extract_overlays(first.config)?
				EnvironmentNix.collect_overlays(
					rest,
					EnvironmentNix.append_unseen(overlays, collected),
				)
			}
		}

	append_unseen = |overlays, collected|
		match overlays {
			[] => collected
			[first, .. as rest] =>
				EnvironmentNix.append_unseen(
					rest,
					if collected.contains(first) {
						collected
					} else {
						collected.append(first)
					},
				)
			}

	all_overlays = |context| {
		entries = Plugin.project_configs(context, ["shell", "environment"])
		overlays = EnvironmentNix.collect_overlays(entries, [])?
		Plugin.renderer_validation(
			Plugin.validate_string_list(overlays, NixBackend.overlay_rules),
		)?
		Ok(overlays)
	}

	all_sources = |context|
		Source.collect(Plugin.project_configs(context, ["source"]))

	validate_source_inputs = |context, selected| {
		sources = EnvironmentNix.all_sources(context)?
		Source.validate_selected(selected, sources, [])
	}

	render_flake =
		|context, pkgs, overlays, export_legacy_packages, unsupported_message| {
			locked_overlays = EnvironmentNix.all_overlays(context)?
			sources = EnvironmentNix.all_sources(context)?
			target = NixBackend.target(context.host_os, context.host_arch) ? |_|
				{ byte_offset: None, message: unsupported_message }
			Ok(
				NixBackend.render_dev_shell({
					export_legacy_packages,
					locked_overlays,
					overlays,
					pkgs,
					sources,
					system: target.system,
				}),
			)
		}

	render_result :
		Plugin.RenderContext,
		List(Str),
		List(Str),
		Str ->
			Try(
				Plugin.RenderResult,
				Plugin.RendererDiagnostic,
			)
	render_result = |context, pkgs, overlays, unsupported_message| {
		flake = EnvironmentNix.render_flake(
			context,
			pkgs,
			overlays,
			Bool.False,
			unsupported_message,
		)?
		Ok(
			Plugin.RenderResult.{
				actions: [],
				artifacts: [],
				outputs: [{ name: "flake", text: flake }],
				requests: [],
				requested_packages: pkgs,
			},
		)
	}
}
