import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Url

import GitHub
import GitHubApi
import Release

PublishRelease := [].{
	git_output! = |args| Ok(Cmd.new_str("git").args_str(args).exec_output!()?.stdout_utf8)
	git! = |args| Cmd.new_str("git").args_str(args).exec_cmd!()

	required_env! = |name| {
		value = Env.var_str!(OsStr.utf8(name))?
		if value.is_empty() {
			Err(EmptyReleaseEnvironment(name))
		} else {
			Ok(value)
		}
	}

	validate_origin! = |repository_name| {
		origin = PublishRelease.git_output!(["config", "--get", "remote.origin.url"])?.trim()
		fetch_urls = PublishRelease.git_output!(["remote", "get-url", "--all", "origin"])?.split_on("\n").keep_if(|line| !line.is_empty())
		push_urls = PublishRelease.git_output!(["remote", "get-url", "--push", "--all", "origin"])?.split_on("\n").keep_if(|line| !line.is_empty())
		expected = "git@github.com:${repository_name}.git"
		matches = match (fetch_urls, push_urls) {
			([fetch_url], [push_url]) =>
				Release.same_github_repository(expected, origin) == Ok(Bool.True) and
					Release.same_github_repository(origin, fetch_url) == Ok(Bool.True) and
						Release.same_github_repository(origin, push_url) == Ok(Bool.True)
			_ => Bool.False
		}
		if matches {
			Ok({})
		} else {
			Err(PublicationOriginMismatch({ fetch_urls, origin, push_urls, repository: repository_name }))
		}
	}

	validate_api = |api| {
		production = Url.scheme(api) == Https and Url.host(api) == "api.github.com" and Url.port(api) == None
		fixture = Url.scheme(api) == Http and Url.host(api) == "127.0.0.1"
		if production or fixture {
			Ok(api)
		} else {
			Err(UnsafeGitHubApiUrl(Url.to_str(api)))
		}
	}

	is_digest = |digest| {
		bytes = Str.to_utf8(digest)
		bytes.len() == 64 and List.all(
			bytes,
			|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'),
		)
	}

	artifact! = |root, name| {
		path = Path.join(Path.join(root, "dist"), name)
		output = Cmd.new_str("sha256sum")
			.args([OsStr.utf8("--"), Path.to_os_str(path)])
			.exec_output!()?
		digest = output.stdout_utf8.split_on(" ").keep_if(|part| !part.is_empty()).first() ?? ""
		if PublishRelease.is_digest(digest) and Path.is_file!(path)? {
			Ok({ digest: "sha256:${digest}", name, path })
		} else {
			Err(InvalidReleaseArtifact({ name, output: output.stdout_utf8 }))
		}
	}

	artifacts_help! = |root, names|
		match names {
			[] => Ok([])
			[name, .. as rest] => Ok([PublishRelease.artifact!(root, name)?].concat(PublishRelease.artifacts_help!(root, rest)?))
		}

	artifacts! = |root, release| PublishRelease.artifacts_help!(root, release.assets)

	tag_message = |contents|
		match contents.split_on("\n\n") {
			[_, message] =>
				if message.ends_with("\n") {
					Ok(Str.from_utf8_lossy(Str.to_utf8(message).drop_last(1)))
				} else {
					Ok(message)
				}
			_ => Err(InvalidAnnotatedTag)
		}

	annotated_tag = |contents, expected_tag|
		match contents.split_on("\n") {
			[object_line, "type commit", tag_line, ..] if object_line.starts_with("object ") and tag_line == "tag ${expected_tag}" => {
				target = Str.join_with(object_line.split_on("object ").drop_first(1), "object ")
				if Release.is_commit_id(target) {
					Ok(AnnotatedTag({ name: PublishRelease.tag_message(contents)?, target_commit: target }))
				} else {
					Err(InvalidAnnotatedTag)
				}
			}
			_ => Err(InvalidAnnotatedTag)
		}

	local_tag_state! = |tag| {
		ref = "refs/tags/${tag}"
		exit_code = Cmd.new_str("git").args_str(["show-ref", "--verify", "--quiet", ref]).exec_exit_code!()?
		if exit_code == 1 {
			Ok(NoTag)
		} else if exit_code != 0 {
			Err(UnexpectedGitExitCode({ command: "show-ref", exit_code }))
		} else {
			kind = PublishRelease.git_output!(["cat-file", "-t", ref])?.trim()
			if kind == "commit" {
				target = PublishRelease.git_output!(["rev-parse", ref])?.trim()
				Ok(LightweightTag(target))
			} else if kind == "tag" {
				contents = PublishRelease.git_output!(["cat-file", "tag", ref])?
				PublishRelease.annotated_tag(contents, tag)
			} else {
				Err(InvalidTagObject(kind))
			}
		}
	}

	remote_tag_state! = |tag| {
		ref = "refs/tags/${tag}"
		remote = PublishRelease.git_output!(["ls-remote", "origin", ref])?
		if remote.is_empty() {
			Ok(NoTag)
		} else {
			PublishRelease.git!(["fetch", "--quiet", "--no-force", "origin", "${ref}:${ref}"])?
			PublishRelease.local_tag_state!(tag)
		}
	}

	require_remote_tag! = |release, expected_assets| {
		state = PublishRelease.remote_tag_state!(release.tag_name)?
		match state {
			AnnotatedTag(_) => {
				_ = GitHub.decide(release, expected_assets, { release: NoRelease, tag: state }) ? RemoteTagMismatch
				Ok({})
			}
			_ => Err(RemoteTagMissingOrLightweight)
		}
	}

	ensure_tag_pushed! = |release, expected_assets| {
		local = PublishRelease.local_tag_state!(release.tag_name)?
		match local {
			NoTag => PublishRelease.git!([
				"-c",
				"user.name=github-actions[bot]",
				"-c",
				"user.email=41898282+github-actions[bot]@users.noreply.github.com",
				"-c",
				"tag.gpgSign=false",
				"tag",
				"--annotate",
				"--cleanup=verbatim",
				"--message",
				release.name,
				release.tag_name,
				release.target_commit,
			])?
			_ => {
				_ = GitHub.decide(release, expected_assets, { release: NoRelease, tag: local }) ? TagCollision
				{}
			}
		}
		match PublishRelease.git!(["-c", "push.followTags=false", "push", "origin", "refs/tags/${release.tag_name}:refs/tags/${release.tag_name}"]) {
			Ok({}) => Ok({})
			Err(_) => {
				state = PublishRelease.remote_tag_state!(release.tag_name)?
				match state {
					AnnotatedTag(_) => {
						_ = GitHub.decide(release, expected_assets, { release: NoRelease, tag: state }) ? AmbiguousTagPushMismatch
						Ok({})
					}
					_ => Err(AmbiguousTagPush)
				}
			}
		}
	}

	run! = || {
		token = PublishRelease.required_env!("GITHUB_TOKEN")?
		repository_name = PublishRelease.required_env!("GITHUB_REPOSITORY")?
		target = PublishRelease.required_env!("GITHUB_SHA")?
		api = PublishRelease.validate_api(Url.parse(PublishRelease.required_env!("GITHUB_API_URL")?) ? InvalidApiUrl)?
		repository = Release.parse_repo_path(repository_name)?
		PublishRelease.validate_origin!(repository_name)?

		status = PublishRelease.git_output!(["status", "--porcelain", "--untracked-files=all"])?
		head = PublishRelease.git_output!(["rev-parse", "HEAD"])?.trim()
		if !status.is_empty() {
			return Err(PublishRequiresCleanTree(status))
		}
		if head != target {
			return Err(PublishTargetMismatch({ actual: head, expected: target }))
		}
		PublishRelease.git!(["fetch", "--quiet", "--no-prune", "--no-tags", "origin", "+refs/heads/master:refs/remotes/origin/master"])?
		ancestor = Cmd.new_str("git").args_str(["merge-base", "--is-ancestor", target, "refs/remotes/origin/master"]).exec_exit_code!()?
		if ancestor != 0 {
			return Err(PublishTargetNotOnMaster)
		}

		version = Path.read_utf8!(Path.utf8("xkai-bin/VERSION"))?
		name = Path.read_utf8!(Path.utf8("xkai-bin/RELEASE_NAME"))?
		manifest = Path.read_utf8!(Path.utf8("build.zig.zon"))?
		manifest_version = Release.manifest_version(manifest) ? InvalidPublicationManifest
		release = Release.validate_publication({
			branch_contains_target: Bool.True,
			branch_name: "master",
			canonical_version: version,
			manifest_version,
			name,
			tag_name: "v${version}",
			target_commit: target,
		}) ? InvalidPublicationMetadata

		GitHubApi.require_repository!(api, repository, token) ? RepositoryProbeFailed
		Cmd.new_str("zig").args_str(["build", "build-release"]).exec_cmd!()?
		root = Env.cwd!()?
		artifacts = PublishRelease.artifacts!(root, release)?
		expected_assets = artifacts.map(|artifact| { digest: artifact.digest, name: artifact.name })
		tag_state = PublishRelease.remote_tag_state!(release.tag_name)?
		release_state = GitHubApi.get_release!(api, repository, release.tag_name, token) ? InspectReleaseFailed
		decision = GitHub.decide(release, expected_assets, { release: release_state, tag: tag_state }) ? PublicationCollision

		draft = match decision {
			AlreadyPublished => {
				Stdout.line!("Release ${release.tag_name} is already published.")?
				return Ok({})
			}
			StartFresh => {
				PublishRelease.ensure_tag_pushed!(release, expected_assets)?
				GitHubApi.create_draft!(api, repository, release, token) ? CreateDraftFailed
			}
			CreateDraft => GitHubApi.create_draft!(api, repository, release, token) ? CreateDraftFailed
			ResumeDraft(resume) => {
				for asset in resume.assets {
					GitHubApi.delete_asset!(api, repository, asset, token) ? DeleteAssetFailed
				}
				{
					assets: [],
					draft: Bool.True,
					id: resume.id,
					name: Ok(release.name),
					prerelease: Bool.False,
					tag_name: release.tag_name,
					upload_url: resume.upload_url,
				}
			}
		}
		PublishRelease.require_remote_tag!(release, expected_assets)?

		for artifact in artifacts {
			GitHubApi.upload_asset!(api, draft.upload_url, artifact, token) ? UploadAssetFailed
		}
		confirmed = match GitHubApi.get_release_by_id!(api, repository, draft.id, token) ? InspectReleaseFailed {
			FoundRelease(found) => found
			NoRelease => return Err(ReleaseDisappeared)
		}
		GitHub.validate_release_identity(release, confirmed) ? ReleaseCollision
		if !confirmed.draft or !GitHub.has_published_assets(confirmed.assets, expected_assets) {
			return Err(UploadedAssetsMismatch)
		}
		PublishRelease.require_remote_tag!(release, expected_assets)?
		GitHubApi.publish_draft!(api, repository, confirmed.id, release, expected_assets, token) ? PublishDraftFailed
		Stdout.line!("Published ${release.name} (${release.tag_name}).")
	}
}
