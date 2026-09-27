# A backend kai can run plans on, and how kai checks that it is usable: kai
# runs `program` with the flag, bounded and side-effect free.
Backend := {
	id : Str,
	summary : Str,
	program : Str,
	flag : [DoubleDashVersion, DashV, VersionWord],
}
