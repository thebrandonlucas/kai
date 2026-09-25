# Checked workflow identities, distinct from task and artifact names.
import ir.Project

WorkflowName :: { name : Str }.{
	from_quote : Str -> Try(WorkflowName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if !Project.valid_name(raw) {
			Err(BadQuotedBytes("invalid workflow name: ${raw}"))
		} else {
			Ok(WorkflowName.{ name: raw })
		}

	to_str : WorkflowName -> Str
	to_str = |value| value.name
}
