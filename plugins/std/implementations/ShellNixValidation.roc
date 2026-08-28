# Temp
import kai.Plugin
import backends.Nix as NixBackend
import commands.Shell as ShellCommand

ShellNixValidation := [].{
	validator : Plugin.Validator
	validator = Validate({
		string_lists: [
			{ field: ShellCommand.packages_field, rules: NixBackend.package_rules },
			{ field: ShellCommand.overlays_field, rules: NixBackend.overlay_rules },
		],
		target: SupportedTargets({
			message: "unsupported shell platform",
			supported: NixBackend.supported_targets,
		}),
	})
}
