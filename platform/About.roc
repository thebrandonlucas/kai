# What kai is, at the top of every help page: the platform's, for a project,
# and kai's own when there is no Kaifile.roc to ask.
About := [].{
	tagline = "A friendly frontend for determinate computing."

	description =
		\\Kai gives determinate systems like Nix and Guix a simple interface. A
		\\project's Kaifile.roc, an ordinary Roc program, describes its
		\\environments, tasks and builds and decides which commands kai offers;
		\\kai asks it how to run each command, checks the plan, and runs it with
		\\every package pinned in .kai/lock.json.

	## The tagline and description, as help prints them.
	text = "${About.tagline}\n\n${About.description}"
}
