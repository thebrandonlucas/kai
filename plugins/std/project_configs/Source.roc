import parser.Body
import parser.Bytes
import kai.Plugin

Source := [].{
	Input := { name : Str, url : Str }

	body : Body.Shape
	body = Body.object([Body.required("url", String)])

	descriptor : Plugin.ProjectConfigDescriptor
	descriptor = {
		block: "source",
		body,
		kind: NamedProjectConfig,
	}

	name_rules : List(Plugin.TextRule)
	name_rules = [
		NonemptyText("source name must not be empty"),
		DisallowedPrefix({ message: "source name must not start with '.'", prefix: "." }),
		AllBytes({
			allowed: [AsciiUppercase, AsciiLowercase, AsciiDigit, ExactByte(Bytes.period), ExactByte(Bytes.underscore), ExactByte(Bytes.hyphen)],
			message: "source name may contain only ASCII letters, digits, '.', '_', and '-'",
		}),
	]

	url_rules : List(Plugin.TextRule)
	url_rules = [
		NonemptyText("source URL must not be empty"),
		BytesInRanges({
			excluded: [Bytes.double_quote, Bytes.dollar_sign, Bytes.backslash],
			message: "source URL contains characters unsafe for Nix output",
			ranges: [{ max: Bytes.tilde, min: Bytes.exclamation_mark }],
		}),
	]

	collect : List(Plugin.ProjectConfigEntry) -> Try(List(Source.Input), Plugin.RendererDiagnostic)
	collect = |entries| {
		inputs = entries.map_try(
			|entry| {
				name = match entry.header {
					["source", selected] | ["source", selected, _] => Ok(selected)
					_ => Err({ byte_offset: None, message: "source declaration requires a name" })
				}?
				url = Body.get_string(entry.config, "url") ? |_|
					{ byte_offset: None, message: "validated source '${name}' is missing 'url'" }
				Ok({ name, url })
			},
		)?
		Source.validate_sources(inputs, [])?
		Ok(inputs)
	}

	validate_sources : List(Source.Input), List(Str) -> Try({}, Plugin.RendererDiagnostic)
	validate_sources = |inputs, seen|
		match inputs {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.renderer_validation(Plugin.validate_text(first.name, Source.name_rules).concat(Plugin.validate_text(first.url, Source.url_rules)))?
				if seen.contains(first.name) {
					Err({ byte_offset: None, message: "source '${first.name}' is declared more than once" })
				} else {
					Source.validate_sources(rest, seen.append(first.name))
				}
			}
		}

	validate_selected : List(Str), List(Source.Input), List(Str) -> Try({}, Plugin.RendererDiagnostic)
	validate_selected = |selected, sources, seen|
		match selected {
			[] => Ok({})
			[first, .. as rest] => {
				Plugin.renderer_validation(Plugin.validate_text(first, Source.name_rules))?
				if seen.contains(first) {
					Err({ byte_offset: None, message: "build input '${first}' is selected more than once" })
				} else if !List.any(sources, |source| source.name == first) {
					Err({ byte_offset: None, message: "build input '${first}' has no declared source; add 'source ${first} { url: ... }'" })
				} else {
					Source.validate_selected(rest, sources, seen.append(first))
				}
			}
		}
}

expect List.all(
	[
		{ expected: Ok({}), selected: ["dep"], sources: [{ name: "dep", url: "https://example.test/dep.tar.gz" }] },
		{ expected: Err("source name must not start with '.'"), selected: [], sources: [{ name: ".dep", url: "https://example.test" }] },
		{ expected: Err("source URL contains characters unsafe for Nix output"), selected: [], sources: [{ name: "dep", url: "https://example.test/$dep" }] },
		{ expected: Err("source 'dep' is declared more than once"), selected: [], sources: [{ name: "dep", url: "a" }, { name: "dep", url: "b" }] },
		{ expected: Err("build input 'dep' is selected more than once"), selected: ["dep", "dep"], sources: [{ name: "dep", url: "a" }] },
		{ expected: Err("build input 'missing' has no declared source; add 'source missing { url: ... }'"), selected: ["missing"], sources: [] },
	],
	|case|
		match Source.validate_sources(case.sources, []) {
			Err(diagnostic) => case.expected == Err(diagnostic.message)
			Ok(_) => match Source.validate_selected(case.selected, case.sources, []) {
				Err(diagnostic) => case.expected == Err(diagnostic.message)
				Ok(value) => case.expected == Ok(value)
			}
		},
)
