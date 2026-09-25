# Checked task identities, optionally dotted, for authored configuration.
import ir.Project

## A task name, checked at compile time.
TaskName :: { name : Str }.{
	from_quote : Str -> Try(TaskName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if !Project.valid_task_name(raw) {
			Err(
				BadQuotedBytes(
					"\"${raw}\" is not a task name; "
						.concat("use letters, digits, ., - or _"),
				),
			)
		} else {
			Ok(TaskName.{ name: raw })
		}

	to_str : TaskName -> Str
	to_str = |value| value.name
}
