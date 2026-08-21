import parser.Body
import kai.Plugin
import backends.Nix as NixBackend
import commands.Shell as ShellCommand

ShellNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: NixBackend.shell_templates,
		backend: NixBackend.backend.name,
		command: ShellCommand.command.name,
		renderer: ShellNix.renderer,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		match context.config_block {
			NoConfigBlock => Err({ byte_offset: None, message: "shell configuration is required" })
			SelectedConfigBlock(_) => Ok({})
		}?
		selected_target = NixBackend.target(context.host_os, context.host_arch) ? |_|
			{ byte_offset: None, message: "unsupported shell platform" }
		pkgs = Body.get_strings(context.config, "packages") ? |_|
			{ byte_offset: None, message: "validated shell configuration is missing 'packages'" }
		maybe_overlays = Body.maybe_strings(context.config, "overlays") ? |_|
			{ byte_offset: None, message: "validated shell configuration has invalid 'overlays'" }
		overlays = match maybe_overlays {
			None => []
			Some(values) => values
		}
		failures = Plugin.validate_string_list(pkgs, NixBackend.package_rules).concat(
			Plugin.validate_string_list(overlays, NixBackend.overlay_rules),
		)
		Plugin.renderer_validation(failures)?
		Ok(ShellNix.render_result(pkgs, overlays, selected_target.system))
	}

	render_result : List(Str), List(Str), Str -> Plugin.RenderResult
	render_result = |pkgs, overlays, system|
		Plugin.RenderResult.{
			actions: [],
			outputs: [{ name: "flake", text: ShellNix.render_nix(pkgs, overlays, system) }],
			requests: [],
			requested_packages: pkgs,
		}

	render_attributes : Str -> Str
	render_attributes = |path|
		Str.join_with(path.split_on(".").map(|part| "\"${part}\""), ".")

	render_nix : List(Str), List(Str), Str -> Str
	render_nix = |pkgs, overlays, system|
		if overlays.is_empty() {
			ShellNix.render_nix_without_overlays(pkgs, system)
		} else {
			ShellNix.render_nix_with_overlays(pkgs, overlays, system)
		}

	# `render_nix_without_overlays(["cowsay"], "x86_64-linux")` renders:
	# {
	#   inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	#   outputs = { nixpkgs, ... }: {
	#     devShells."x86_64-linux".default = nixpkgs.legacyPackages."x86_64-linux".mkShell {
	#       packages = [
	#               nixpkgs."legacyPackages"."x86_64-linux"."cowsay"
	#       ];
	#     };
	#   };
	# }
	render_nix_without_overlays : List(Str), Str -> Str
	render_nix_without_overlays = |pkgs, system| {
		package_lines = pkgs.map(
			|pkg| "              nixpkgs.\"legacyPackages\".\"${system}\".${ShellNix.render_attributes(pkg)}",
		)
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
			"  outputs = { nixpkgs, ... }: {",
			"    devShells.\"${system}\".default = nixpkgs.legacyPackages.\"${system}\".mkShell {",
			"      packages = [",
		].concat(package_lines).concat([
			"      ];",
			"    };",
			"  };",
			"}",
		])
		Str.join_with(lines, "\n")
	}

	# `render_nix_with_overlays(["cowsay"], ["github:example/packages"], "x86_64-linux")` renders:
	# {
	#   inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	#   inputs.overlay0.url = "github:example/packages";
	#   outputs = { nixpkgs, overlay0, ... }:
	#     let
	#       pkgs = import nixpkgs {
	#         system = "x86_64-linux";
	#         overlays = [
	#           overlay0.overlays.default
	#         ];
	#       };
	#     in {
	#       devShells."x86_64-linux".default = pkgs.mkShell {
	#         packages = [
	#               pkgs."cowsay"
	#         ];
	#       };
	#     };
	# }
	render_nix_with_overlays : List(Str), List(Str), Str -> Str
	render_nix_with_overlays = |pkgs, overlays, system| {
		overlay_names = overlays.map_with_index(|_, index| "overlay${U64.to_str(index)}")
		input_lines = overlays.map_with_index(
			|overlay, index| "  inputs.overlay${U64.to_str(index)}.url = \"${overlay}\";",
		)
		overlay_lines = overlay_names.map(|name| "          ${name}.overlays.default")
		package_lines = pkgs.map(
			|pkg| "              pkgs.${ShellNix.render_attributes(pkg)}",
		)
		outputs_args = Str.join_with(["nixpkgs"].concat(overlay_names), ", ")
		lines = [
			"{",
			"  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";",
		].concat(input_lines).concat([
			"  outputs = { ${outputs_args}, ... }:",
			"    let",
			"      pkgs = import nixpkgs {",
			"        system = \"${system}\";",
			"        overlays = [",
		]).concat(overlay_lines).concat([
			"        ];",
			"      };",
			"    in {",
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
}
