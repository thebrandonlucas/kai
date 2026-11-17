# Checked tool references that convert into model tools for environments.
import model.Model
import model.Project

## A provider-native tool name, optionally qualified as "source#name".
## Generic syntax is checked here; explicit source grammar is checked during
## whole-project validation. Auto sources are interpreted by the chosen backend.
## A bare name names the project's Fetch of that name, if it declares one,
## and otherwise the `default` source; "default#name" is always the package.
Tool :: { source : Str, name : Str }.{
	from_quote : Str -> Try(Tool, [BadQuotedBytes(Str)])
	from_quote = |raw|
		match Project.tool(raw) {
			Ok(tool) => {
				# A bare name has no source until the project's fetches are known.
				source = if (raw.contains("#")) tool.source else ""
				Ok(Tool.{ source, name: tool.name })
			}
			Err(error) => Err(BadQuotedBytes(error))
		}

	## The model tool, given the names of the project's fetches.
	to_ir : Tool, List(Str) -> Model.Tool
	to_ir = |tool, fetches|
		if tool.source != "" {
			{ source: tool.source, name: tool.name }
		} else if fetches.contains(tool.name) {
			{ source: tool.name, name: tool.name }
		} else {
			{ source: "default", name: tool.name }
		}

	to_str : Tool -> Str
	to_str = |tool|
		if tool.source == "" {
			tool.name
		} else {
			"${tool.source}#${tool.name}"
		}
}
