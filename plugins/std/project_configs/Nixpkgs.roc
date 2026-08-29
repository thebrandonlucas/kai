# Project-level Nixpkgs sources selected by target system.
import parser.Fields
import kai.Kaifile
import kai.Plugin

Nixpkgs := [].{
	Selection := { selector : Str, url : Str }

	default_url = "github:NixOS/nixpkgs/nixos-unstable"

	supported_selectors = [
		"default",
		"x86_64-linux",
		"aarch64-linux",
		"x86_64-darwin",
		"aarch64-darwin",
	]

	selector_rules : List(Plugin.TextRule)
	selector_rules = [
		NonemptyText("nixpkgs selector must not be empty"),
		AllBytes({
			allowed: [
				AsciiLowercase,
				AsciiDigit,
				ExactByte('-'),
				ExactByte('_'),
			],
			message: Str.join_with(
				[
					"nixpkgs selector may contain only lowercase ASCII letters, ",
					"digits, '-' and '_'",
				],
				"",
			),
		}),
	]

	url_rules : List(Plugin.TextRule)
	url_rules = [
		NonemptyText("nixpkgs URL must not be empty"),
		BytesInRanges({
			excluded: ['"', '$', '\\'],
			message: "nixpkgs URL contains characters unsafe for Nix output",
			ranges: [{ max: '~', min: '!' }],
		}),
	]

	block : Plugin.KaifileBlock
	block = Kaifile.named_block({
		header: "nixpkgs <system>",
		fields: [Kaifile.required("url", String)],
		name_rules: selector_rules,
	})

	descriptor : Plugin.ProjectConfigDescriptor
	descriptor = block

	collect :
		List(Plugin.ProjectConfigEntry) -> Try(
			List(Nixpkgs.Selection),
			Plugin.RendererDiagnostic,
		)
	collect = |entries| {
		selections = entries.map_try(
			|entry| {
				selector = match entry.header {
					["nixpkgs", selected] | ["nixpkgs", selected, _] => Ok(selected)
					_ => Err({
						byte_offset: None,
						message: "nixpkgs declaration requires a system selector",
					})
				}?
				url = Fields.get_string(entry.config, "url") ? |_|
					{
						byte_offset: None,
						message: "validated nixpkgs '${selector}' is missing 'url'",
					}
				Ok({ selector, url })
			},
		)?
		Nixpkgs.validate(selections, [])?
		Ok(selections)
	}

	validate :
		List(Nixpkgs.Selection), List(Str) -> Try({}, Plugin.RendererDiagnostic)
	validate = |selections, seen|
		match selections {
			[] => Ok({})
			[first, .. as rest] => {
				failures = Plugin.validate_text(first.selector, Nixpkgs.selector_rules)
					.concat(Plugin.validate_text(first.url, Nixpkgs.url_rules))
				Plugin.renderer_validation(failures)?
				if !Nixpkgs.supported_selectors.contains(first.selector) {
					Err({
						byte_offset: None,
						message: "unsupported nixpkgs selector '${first.selector}'",
					})
				} else if seen.contains(first.selector) {
					Err({
						byte_offset: None,
						message: "duplicate nixpkgs selector '${first.selector}'",
					})
				} else {
					Nixpkgs.validate(rest, seen.append(first.selector))
				}
			}
		}

	select : Plugin.RenderContext, Str -> Try(Str, Plugin.RendererDiagnostic)
	select = |context, system| {
		selections = Nixpkgs.collect(
			Plugin.project_configs(context, ["nixpkgs"]),
		)?
		Ok(Nixpkgs.select_from(selections, system))
	}

	select_from : List(Nixpkgs.Selection), Str -> Str
	select_from = |selections, system|
		match selections.keep_if(|selection| selection.selector == system) {
			[first, ..] => first.url
			[] =>
				match selections.keep_if(|selection| selection.selector == "default") {
					[first, ..] => first.url
					[] => Nixpkgs.default_url
				}
			}
}
