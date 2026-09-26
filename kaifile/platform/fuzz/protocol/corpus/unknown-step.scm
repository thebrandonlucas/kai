(
	(body (Candidates (
		(choice Auto)
		(command "build")
		(options ((
			(backend "guix")
			(outcome (Unfit "uses Nix overlays"))
			(plugin "std")
			(probes ((
				(flag DashV)
				(program "guix"))))) (
			(backend "nix")
			(outcome (Planned (
				(next (Observe ("/g/flake.lock")))
				(steps ((Delete "n") (Print "p") (Stage "run test") (Confirm "go?") (Write ((
					(contents "{ }\n")
					(path "/g/flake.nix")))) (VerifyPath (
					(argv ("nix" "hash" "path" "--sri" "/p/src"))
					(path "/p/src")
					(stdout "sha256-x"))) (Snapshot (
					(destination "/w/src")
					(exclude (".git"))
					(root "/p"))) (InstallRunner (
					(destination "/w/runner"))) (Run (
					(argv ("bash"))
					(output Inherit)
					(what "shell dev"))) (Run (
					(argv ("nix" "build"))
					(output (Artifact (
						(label "site")
						(name "site")
						(output "out"))))
					(what "build site"))) (PublishLock (
					(contents "{ }")
					(previous (Present "{}")))))))))
			(plugin "std")
			(probes ((
				(flag DoubleDashVersion)
				(program "nix"))))) (
			(backend "")
			(outcome (Failed "no"))
			(plugin "x")
			(probes ()))))
		(plugin "std"))))
	(platform "0.0.8")
	(protocol (
		(major 1)
		(minor 0))))
