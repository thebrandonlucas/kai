(
	(argv ("shell" "--backend" "nix" "--" "-x"))
	(host (
		(system "x86_64-linux")))
	(layout (
		(generated_root "/p/.kai/generated")
		(lock_path "/p/.kai/lock.json")
		(project_root "/p")
		(workspace "/p/.kai")))
	(lock (Present "{\n\t\"version\": 1\n}\n"))
	(protocol (
		(major 1)
		(minor 0)))
	(resume (Resume (
		(backend "nix")
		(command "update")
		(observed ((
			(contents (Text "{}"))
			(path "/p/.kai/generated/flake.lock")) (
			(contents Missing)
			(path "/x"))))
		(phase 1))))
	(style Plain))
