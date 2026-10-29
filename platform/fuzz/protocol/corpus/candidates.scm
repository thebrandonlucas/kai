(
	(body (Candidates (
		(choice Auto)
		(lock ReadsLock)
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
				(steps ((Note "n") (Print "p") (Stage "run test") (MayFail 1) (Confirm "go?") (Write ((
					(contents "{ }\n")
					(path "/g/flake.nix")))) (VerifyPath (
					(argv ("nix" "hash" "path" "--sri" "/p/src"))
					(path "/p/src")
					(stdout "sha256-x"))) (Snapshot (
					(destination "/w/src")
					(exclude (".git"))
					(files (Only ("src")))
					(root "/p")
					(store "/nix/store"))) (InstallRunner (
					(destination "/w/runner"))) (Run (
					(argv ("bash"))
					(output Inherit)
					(secrets ("TOKEN"))
					(description "task t")
					(removed_environment_variables ("OTHER"))
					(kept_environment_variables ("VERSION")))) (Run (
					(argv ("nix" "build"))
					(output (Artifact (
						(label "site")
						(name "site")
						(output "out"))))
					(secrets ())
					(description "build site")
					(removed_environment_variables ())
					(kept_environment_variables ()))) (PublishLock (
					(contents "{ }")
					(previous (Present "{}")))))))))
			(plugin "std")
			(probes ((
				(flag DoubleDashVersion)
				(program "nix"))))) (
			(backend "")
			(outcome (Failed "no"))
			(plugin "x")
			(probes ())) (
			(backend "nix")
			(outcome (Failure (
				(code "missing_lock")
				(hint "kai update")
				(message "no lock file at /p/.kai/lock.json")
				(suggestions ()))))
			(plugin "std")
			(probes ()))))
		(plugin "std"))))
	(platform "0.0.8")
	(protocol (
		(major 1)
		(minor 2))))
