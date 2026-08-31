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
				overlays = EnvironmentNix.extract_overlays(first.fields)?
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

	all_overlays = |input| {
		entries = Plugin.blocks_of_kind(input, ["shell", "environment"])
		overlays = EnvironmentNix.collect_overlays(entries, [])?
		Plugin.implementation_validation(
			Plugin.validate_string_list(overlays, NixBackend.overlay_rules),
		)?
		Ok(overlays)
	}

	all_sources = |input|
		Source.collect(Plugin.blocks_of_kind(input, ["source"]))

	validate_source_inputs = |input, selected| {
		sources = EnvironmentNix.all_sources(input)?
		Source.validate_selected(selected, sources, [])
	}

	render_flake =
		|input, pkgs, overlays, export_legacy_packages, unsupported_message| {
			locked_overlays = EnvironmentNix.all_overlays(input)?
			sources = EnvironmentNix.all_sources(input)?
			target = NixBackend.target(input.host.os, input.host.arch) ? |_|
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

	command_plan :
		Plugin.ImplementationInput,
		List(Str),
		List(Str),
		Str ->
			Try(
				Plugin.CommandPlan,
				Plugin.ImplementationDiagnostic,
			)
	command_plan = |input, pkgs, overlays, unsupported_message| {
		flake = EnvironmentNix.render_flake(
			input,
			pkgs,
			overlays,
			Bool.False,
			unsupported_message,
		)?
		Ok(
			Plugin.CommandPlan.{
				actions: [],
				artifacts: [],
				outputs: [{ name: "flake", text: flake }],
				prerequisite_commands: [],
				requested_packages: pkgs,
			},
		)
	}
}
