# Data-driven checks for import parsing and expansion.
import parser.Imports

ImportCheck := [].{
	line = |source, expected| Imports.parse_import_line(source) == expected
	expansion = |actual, expected| actual == expected
}
