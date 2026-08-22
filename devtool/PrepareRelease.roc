import pf.Cmd
import pf.Env
import pf.Path
import pf.Stderr
import pf.Stdout

import Release

PrepareRelease := [].{
	validate_metadata! = || {
		version = Path.read_utf8!(Path.utf8("xkai-bin/VERSION"))?
		if !Release.is_semver(version) {
			Err(InvalidReleaseVersion(version))
		} else {
			manifest = Path.read_utf8!(Path.utf8("build.zig.zon"))?
			manifest_version = match Release.manifest_version(manifest) {
				Ok(found) => found
				Err(error) => return Err(InvalidReleaseManifest(error))
			}
			if manifest_version == version {
				Ok(version)
			} else {
				Err(ManifestVersionMismatch({ canonical: version, manifest: manifest_version }))
			}
		}
	}
	remove_stale_workspaces! = |root| {
		for entry in Path.list!(root)? {
			name = Path.display(Path.filename(entry) ?? entry)
			if Release.is_release_workspace(name) and !Path.is_sym_link!(entry)? and Path.is_dir!(entry)? {
				Path.delete_all!(entry)?
			}
		}
		Ok({})
	}
	git_output! = |args| Ok(Cmd.new_str("git").args_str(args).exec_output!()?.stdout_utf8)
	git! = |args| Cmd.new_str("git").args_str(args).exec_cmd!()
	git_lines! = |args| Ok(PrepareRelease.git_output!(args)?.split_on("\n").keep_if(|line| !line.is_empty()))
	require_local_ref_absent! = |ref| {
		exit_code = Cmd.new_str("git")
			.args_str(["show-ref", "--verify", "--quiet", ref])
			.exec_exit_code!()?
		match exit_code {
			0 => Err(LocalReleaseRefExists(ref))
			1 => Ok({})
			_ => Err(UnexpectedGitExitCode({ command: "show-ref", exit_code }))
		}
	}
	require_remote_ref_absent! = |ref| {
		output = PrepareRelease.git_output!(["ls-remote", "origin", ref])?
		if output.is_empty() {
			Ok({})
		} else {
			Err(RemoteReleaseRefExists(ref))
		}
	}
	remove_release_outputs! = || {
		root = Env.cwd!()?
		dist = Path.join(root, "dist")
		if Path.exists!(dist)? {
			if Path.is_sym_link!(dist)? or !Path.is_dir!(dist)? {
				Stderr.line!("error: rollback refused to remove unexpected path: dist")?
				return Err(UnexpectedRollbackPath("dist"))
			}
			Path.delete_all!(dist)?
		}
		PrepareRelease.remove_stale_workspaces!(root)?
		Ok({})
	}
	delete_release_branch_if_exists! = |branch| {
		ref = "refs/heads/${branch}"
		exit_code = Cmd.new_str("git")
			.args_str(["show-ref", "--verify", "--quiet", ref])
			.exec_exit_code!()?
		match exit_code {
			0 => PrepareRelease.git!(["branch", "--delete", "--force", branch])
			1 => Ok({})
			_ => Err(UnexpectedGitExitCode({ command: "show-ref", exit_code }))
		}
	}
	rollback_release_branch! = |starting_head, branch| {
		PrepareRelease.git!(["reset", "--hard", "refs/remotes/origin/master"])?
		PrepareRelease.remove_release_outputs!()?
		PrepareRelease.git!(["switch", "--quiet", "master"]) ?? {}
		current_branch = PrepareRelease.git_output!(["branch", "--show-current"])?.trim()
		if current_branch != "master" {
			Stderr.line!("error: rollback could not restore master; current branch: ${current_branch}")?
			return Err(RollbackMasterRestoreFailed(current_branch))
		}
		PrepareRelease.git!(["reset", "--hard", starting_head])?
		PrepareRelease.delete_release_branch_if_exists!(branch)?
		status = PrepareRelease.git_output!(["status", "--porcelain", "--untracked-files=all"])?
		final_head = PrepareRelease.git_output!(["rev-parse", "HEAD"])?.trim()
		if !status.is_empty() or final_head != starting_head {
			Stderr.line!("error: rollback did not restore the original tracked state")?
			Err(LocalReleaseRestoreFailed({ expected_head: starting_head, final_head, final_status: status }))
		} else {
			Ok({})
		}
	}
	fail_and_rollback! = |error, starting_head, branch|
		match PrepareRelease.rollback_release_branch!(starting_head, branch) {
			Ok({}) => {
				Stderr.line!("error: release failed; local release changes were rolled back")?
				Err(error)
			}
			Err(_) => Err(ReleaseRollbackFailed(branch))
		}

	verify_release_changes! = || {
		changed = PrepareRelease.git_lines!(["diff", "--name-only"])?
		untracked = PrepareRelease.git_lines!(["ls-files", "--others", "--exclude-standard"])?
		if !Release.are_allowed_release_files(changed) or !untracked.is_empty() {
			Err(UnexpectedReleaseFiles({ changed, untracked }))
		} else {
			PrepareRelease.git!(["add", "--", "build.zig.zon", "xkai-bin/RELEASE_NAME", "xkai-bin/VERSION"])?
			staged = PrepareRelease.git_lines!(["diff", "--cached", "--name-only"])?
			unstaged = PrepareRelease.git_lines!(["diff", "--name-only"])?
			if Release.are_allowed_release_files(staged) and unstaged.is_empty() {
				Ok({})
			} else {
				Err(UnexpectedStagedReleaseFiles({ staged, unstaged }))
			}
		}
	}
	write_release_metadata! = |name, version| {
		manifest_path = Path.utf8("build.zig.zon")
		manifest = Path.read_utf8!(manifest_path)?
		rewritten = match Release.rewrite_manifest(manifest, version) {
			Ok(value) => value
			Err(error) => return Err(InvalidReleaseRewrite(error))
		}
		Path.write_utf8!(Path.utf8("xkai-bin/VERSION"), version)?
		Path.write_utf8!(Path.utf8("xkai-bin/RELEASE_NAME"), name)?
		Path.write_utf8!(manifest_path, rewritten)?
		Ok({})
	}
	build_release_branch! = |name, version, tag, branch| {
		PrepareRelease.write_release_metadata!(name, version)?
		Stdout.line!("Building and checking ${name} (${version})...")?
		Cmd.new_str("zig").args_str(["build", "build-release"]).exec_cmd!()?
		PrepareRelease.verify_release_changes!()?
		PrepareRelease.git!(["commit", "--no-gpg-sign", "-m", "Release ${name}"])?
		committed = PrepareRelease.git_lines!(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])?
		if !Release.are_allowed_release_files(committed) {
			Err(UnexpectedReleaseCommitFiles(committed))
		} else {
			PrepareRelease.require_local_ref_absent!("refs/tags/${tag}")?
			PrepareRelease.require_remote_ref_absent!("refs/tags/${tag}")?
			PrepareRelease.require_remote_ref_absent!("refs/heads/${branch}")?
			Ok({})
		}
	}

	validate_release_origin! = |expected_origin| {
		origin = PrepareRelease.git_output!(["config", "--get", "remote.origin.url"])?.trim()
		fetch_urls = PrepareRelease.git_lines!(["remote", "get-url", "--all", "origin"])?
		push_urls = PrepareRelease.git_lines!(["remote", "get-url", "--push", "--all", "origin"])?
		urls_match = match (fetch_urls, push_urls) {
			([fetch_url], [push_url]) =>
				Release.same_github_repository(expected_origin, origin) == Ok(Bool.True) and
					Release.same_github_repository(origin, fetch_url) == Ok(Bool.True) and
						Release.same_github_repository(origin, push_url) == Ok(Bool.True)
			_ => Bool.False
		}
		if urls_match {
			Ok(origin)
		} else {
			Err(ReleaseOriginPushMismatch({ origin, fetch_urls, push_urls }))
		}
	}

	push_release_branch! = |branch| {
		ref = "refs/heads/${branch}"
		match PrepareRelease.git!(["-c", "push.followTags=false", "push", "--force-with-lease=${ref}:", "origin", "${ref}:${ref}"]) {
			Err(_) => {
				Stderr.line!("error: push status is ambiguous; local release state was retained")?
				Stderr.line!("error: inspect with: git ls-remote origin ${ref}")?
				Stderr.line!("error: return with: git switch master")?
				Err(AmbiguousReleasePush(branch))
			}
			Ok({}) => Ok({})
		}
	}

	finish_release! = |starting_head, branch, url| {
		PrepareRelease.git!(["switch", "--quiet", "master"])?
		final_head = PrepareRelease.git_output!(["rev-parse", "HEAD"])?.trim()
		final_status = PrepareRelease.git_output!(["status", "--porcelain", "--untracked-files=all"])?
		if final_head != starting_head or !final_status.is_empty() {
			Err(LocalReleaseRestoreFailed({ expected_head: starting_head, final_head, final_status }))
		} else {
			PrepareRelease.git!(["branch", "--delete", "--force", branch])?
			Stdout.line!("Release branch pushed. Open the required pull request:")?
			Stdout.line!(url)
		}
	}

	run! = |name, version| {
		if !Release.is_release_name(name) {
			return Err(InvalidReleaseName)
		}
		if !Release.is_semver(version) {
			return Err(InvalidRequestedVersion(version))
		}

		initial_branch = PrepareRelease.git_output!(["branch", "--show-current"])?.trim()
		initial_status = PrepareRelease.git_output!(["status", "--porcelain", "--untracked-files=all"])?
		if initial_branch != "master" {
			return Err(ReleaseRequiresMaster(initial_branch))
		}
		if !initial_status.is_empty() {
			return Err(ReleaseRequiresCleanTree(initial_status))
		}

		configured_origin = PrepareRelease.git_output!(["config", "--get", "remote.origin.url"])?.trim()
		url = match Release.pull_request_url(configured_origin, version) {
			Ok(value) => value
			Err(_) => return Err(UnsupportedReleaseOrigin(configured_origin))
		}
		origin = PrepareRelease.validate_release_origin!(configured_origin)?
		PrepareRelease.git!(["fetch", "--quiet", "--no-prune", "--no-tags", "origin", "+refs/heads/master:refs/remotes/origin/master"])?

		branch = PrepareRelease.git_output!(["branch", "--show-current"])?.trim()
		status = PrepareRelease.git_output!(["status", "--porcelain", "--untracked-files=all"])?
		starting_head = PrepareRelease.git_output!(["rev-parse", "HEAD"])?.trim()
		remote_head = PrepareRelease.git_output!(["rev-parse", "refs/remotes/origin/master"])?.trim()
		if branch != "master" {
			return Err(ReleaseRequiresMaster(branch))
		}
		if !status.is_empty() {
			return Err(ReleaseRequiresCleanTree(status))
		}
		if starting_head != remote_head {
			return Err(MasterNotSynced({ local: starting_head, remote: remote_head }))
		}

		current_version = PrepareRelease.validate_metadata!()?
		if Release.version_order(version, current_version) != Ok(GT) {
			return Err(ReleaseVersionNotNewer({ requested: version, current: current_version }))
		}

		tag = "v${version}"
		release_branch = "release/${tag}"
		PrepareRelease.require_local_ref_absent!("refs/tags/${tag}")?
		PrepareRelease.require_remote_ref_absent!("refs/tags/${tag}")?
		PrepareRelease.require_local_ref_absent!("refs/heads/${release_branch}")?
		PrepareRelease.require_remote_ref_absent!("refs/heads/${release_branch}")?

		switch_result = PrepareRelease.git!(["switch", "--quiet", "--no-track", "--create", release_branch, "refs/remotes/origin/master"])
		match switch_result {
			Err(error) => PrepareRelease.fail_and_rollback!(error, starting_head, release_branch)
			Ok({}) =>
				match PrepareRelease.build_release_branch!(name, version, tag, release_branch) {
					Err(error) => PrepareRelease.fail_and_rollback!(error, starting_head, release_branch)
					Ok({}) =>
						match PrepareRelease.validate_release_origin!(origin) {
							Err(error) => PrepareRelease.fail_and_rollback!(error, starting_head, release_branch)
							Ok(_) => {
								PrepareRelease.push_release_branch!(release_branch)?
								match PrepareRelease.finish_release!(starting_head, release_branch, url) {
									Ok({}) => Ok({})
									Err(_) => {
										Stderr.line!("error: release branch was pushed, but local cleanup failed")?
										Stderr.line!("error: inspect remote branch: ${release_branch}")?
										Stderr.line!("error: pull request: ${url}")?
										Err(ReleasePushedCleanupFailed(release_branch))
									}
								}
							}
						}
					}
			}
	}
}
