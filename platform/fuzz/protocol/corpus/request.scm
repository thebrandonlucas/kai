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
		(minor 1)))
	(resume (Resume (
		(backend "nix")
		(command "update")
		(observed ((
			(contents (Text "{}"))
			(path "/p/.kai/generated/flake.lock")) (
			(contents Missing)
			(path "/x"))))
		(phase 1))))
	(revision (
		(commit_date "2026-01-02")
		(describe "v1.0-2-gabc1234-dirty")))
	(style Plain)
	(working_directory "/p"))
