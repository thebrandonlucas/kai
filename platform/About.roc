# What kai is, at the top of every help page: the platform's, for a project,
# and kai's own when there is no Kaifile.roc to ask.
About := [].{
	tagline = "A friendly frontend for determinate computing."

	description =
		\\Kai gives determinate systems like Nix and Guix a simple interface.
		\\Projects can be managed by a Kaifile.roc, a Roc program which can
		\\describe reproducible environments, tasks, builds, shells, and more.

	## The tagline and description, as help prints them.
	text = "${About.tagline}\n\n${About.description}"
}
