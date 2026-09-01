# An implementation for interfacing between Kai environment blocks and
# the Nix backend.
import kai.Plugin
import backends.Nix as NixBackend
import blocks.Environment as EnvironmentBlock
import blocks.Source as SourceBlock

EnvironmentNix := [].{
	extract_overlays = |fields|
		Plugin.validated_strings(fields, EnvironmentBlock.overlays_field)

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
		SourceBlock.collect(Plugin.blocks_of_kind(input, ["source"]))

	validate_source_inputs = |input, selected| {
		sources = EnvironmentNix.all_sources(input)?
		SourceBlock.validate_selected(selected, sources, [])
	}

	# Render a flake containing a dev shell backed directly by nixpkgs.
	render_dev_shell_flake_without_overlays :
		List(Str), List(SourceBlock.Input), Str, Bool -> Str
	render_dev_shell_flake_without_overlays = |pkgs, sources, system, legacy| {
		package_lines = pkgs.map(
			|pkg|
				Str.join_with(
					[
						"              nixpkgs.\"legacyPackages\".\"${system}\".",
						NixBackend.render_attribute_path(pkg),
					],
					"",
				),
		)
		legacy_lines = if legacy {
			["    legacyPackages.\"${system}\" = nixpkgs.legacyPackages.\"${system}\";"]
		} else {
			[]
		}
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		].concat(NixBackend.source_input_lines(sources)).concat([
			"  outputs = inputs@{ nixpkgs, ... }: {",
			"    ${NixBackend.source_attribute(sources)}",
		]).concat(legacy_lines).concat([
			Str.join_with(
				[
					"    devShells.\"${system}\".default = ",
					"nixpkgs.legacyPackages.\"${system}\".mkShell {",
				],
				"",
			),
			"      packages = [",
		]).concat(package_lines).concat([
			"      ];",
			"    };",
			"  };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	# Render a flake containing a dev shell with additional flake overlays.
	render_dev_shell_flake_with_overlays :
		List(Str), List(Str), List(Str), List(SourceBlock.Input), Str -> Str
	render_dev_shell_flake_with_overlays =
		|pkgs, locked, overlays, sources, system| {
			overlay_lines = overlays.map(
				|overlay|
					"          ${NixBackend.overlay_expression(locked, overlay, 0)}",
			)
			package_lines = pkgs.map(
				|pkg| "              pkgs.${NixBackend.render_attribute_path(pkg)}",
			)
			outputs_args = NixBackend.overlay_outputs_args(locked)
			lines = [
				"{",
				"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
			]
				.concat(NixBackend.input_lines(locked))
				.concat(NixBackend.source_input_lines(sources))
				.concat([
					"  outputs = inputs@{ ${outputs_args}, ... }:",
					"    let",
					"      pkgs = import nixpkgs {",
					"        system = \"${system}\";",
					"        overlays = [",
				]).concat(overlay_lines).concat([
				"        ];",
				"      };",
				"    in {",
				"      ${NixBackend.source_attribute(sources)}",
				"      legacyPackages.\"${system}\" = pkgs;",
				"      devShells.\"${system}\".default = pkgs.mkShell {",
				"        packages = [",
			]).concat(package_lines).concat([
				"        ];",
				"      };",
				"    };",
				"}",
			])
			Str.join_with(lines, "\n")
		}

	render_flake =
		|input, pkgs, overlays, export_legacy_packages, unsupported_message| {
			locked_overlays = EnvironmentNix.all_overlays(input)?
			sources = EnvironmentNix.all_sources(input)?
			target = NixBackend.target(input.host.os, input.host.arch) ? |_|
				{ byte_offset: None, message: unsupported_message }
			flake = if locked_overlays.is_empty() {
				EnvironmentNix.render_dev_shell_flake_without_overlays(
					pkgs,
					sources,
					target.system,
					export_legacy_packages,
				)
			} else {
				EnvironmentNix.render_dev_shell_flake_with_overlays(
					pkgs,
					locked_overlays,
					overlays,
					sources,
					target.system,
				)
			}
			Ok(flake)
		}

}
