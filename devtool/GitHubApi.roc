import pf.Http
import pf.Path
import pf.Url
import http.Request
import http.Response

import GitHub
import Release

GitHubApi := [].{
	response_body = |response|
		Str.from_utf8(Response.body(response)) ?? "<non-UTF-8 response>"

	request = |method, url, token|
		Request.from_method(method)
			.with_uri(Url.to_str(url))
			.with_timeout(TimeoutMilliseconds(120000))
			.add_header("Authorization", "Bearer ${token}")
			.add_header("Accept", "application/vnd.github+json")
			.add_header("X-GitHub-Api-Version", "2022-11-28")
			.add_header("User-Agent", "kai-release-devtool")

	require_status = |response, expected| {
		actual = Response.status(response)
		if actual == expected {
			Ok(response)
		} else {
			Err(UnexpectedGitHubStatus({ actual, body: GitHubApi.response_body(response), expected }))
		}
	}

	decode_release_response = |response| {
		body = GitHubApi.response_body(response)
		match GitHub.decode_release(body) {
			Ok(release) => Ok(release)
			Err(_) => Err(InvalidGitHubRelease(body))
		}
	}

	require_repository! = |api, repository, token| {
		url = Url.append_path_segments(api, ["repos", repository.owner, repository.repository])
		response = Http.send!(GitHubApi.request(GET, url, token))?
		_ = GitHubApi.require_status(response, 200)?
		Ok({})
	}

	release_url = |api, repository, tag|
		Url.append_path_segments(api, ["repos", repository.owner, repository.repository, "releases", "tags", tag])

	releases_url = |api, repository|
		Url.append_path_segments(api, ["repos", repository.owner, repository.repository, "releases"])

	release_by_id_url = |api, repository, id|
		Url.append_path_segments(api, ["repos", repository.owner, repository.repository, "releases", U64.to_str(id)])

	get_release! = |api, repository, tag, token| {
		response = Http.send!(GitHubApi.request(GET, GitHubApi.release_url(api, repository, tag), token))?
		match Response.status(response) {
			200 => Ok(FoundRelease(GitHubApi.decode_release_response(response)?))
			404 => Ok(NoRelease)
			status => Err(UnexpectedGitHubStatus({ actual: status, body: GitHubApi.response_body(response), expected: 200 }))
		}
	}

	get_release_by_id! = |api, repository, id, token| {
		response = Http.send!(GitHubApi.request(GET, GitHubApi.release_by_id_url(api, repository, id), token))?
		match Response.status(response) {
			200 => Ok(FoundRelease(GitHubApi.decode_release_response(response)?))
			404 => Ok(NoRelease)
			status => Err(UnexpectedGitHubStatus({ actual: status, body: GitHubApi.response_body(response), expected: 200 }))
		}
	}

	create_draft! = |api, repository, release, token| {
		api_request = GitHubApi.request(POST, GitHubApi.releases_url(api, repository), token)
		response = Http.send_json!(api_request, GitHub.create_release_request(release))?
		_ = GitHubApi.require_status(response, 201)?
		draft = GitHubApi.decode_release_response(response)?
		GitHub.validate_release_identity(release, draft) ? ReleaseCollision
		if draft.draft {
			Ok(draft)
		} else {
			Err(CreatedReleaseWasNotDraft)
		}
	}

	delete_asset! = |api, repository, asset, token| {
		url = Url.append_path_segments(api, ["repos", repository.owner, repository.repository, "releases", "assets", U64.to_str(asset.id)])
		response = Http.send!(GitHubApi.request(DELETE, url, token))?
		status = Response.status(response)
		if status == 204 or status == 404 {
			Ok({})
		} else {
			Err(UnexpectedGitHubStatus({ actual: status, body: GitHubApi.response_body(response), expected: 204 }))
		}
	}

	same_origin = |left, right|
		Url.scheme(left) == Url.scheme(right) and Url.host(left) == Url.host(right) and Url.port(left) == Url.port(right)

	upload_base = |api, template| {
		raw = template.split_on("{").first() ?? template
		upload = Url.parse(raw) ? InvalidUploadUrl
		production = Url.scheme(api) == Https and Url.host(api) == "api.github.com"
		allowed = if production {
			Url.scheme(upload) == Https and Url.host(upload) == "uploads.github.com"
		} else {
			GitHubApi.same_origin(api, upload)
		}
		if allowed {
			Ok(upload)
		} else {
			Err(UnexpectedUploadOrigin(template))
		}
	}

	upload_asset! = |api, template, artifact, token| {
		base = GitHubApi.upload_base(api, template)?
		url = Url.append_query_param(base, "name", artifact.name)
		upload_request = GitHubApi.request(POST, url, token)
			.add_header("Content-Type", "application/octet-stream")
			.with_body(Path.read_bytes!(artifact.path)?)
		response = Http.send!(upload_request)?
		_ = GitHubApi.require_status(response, 201)?
		Ok({})
	}

	publish_draft! = |api, repository, id, release, expected_assets, token| {
		url = GitHubApi.release_by_id_url(api, repository, id)
		response = Http.send_json!(GitHubApi.request(PATCH, url, token), { draft: Bool.False })?
		_ = GitHubApi.require_status(response, 200)?
		published = GitHubApi.decode_release_response(response)?
		GitHub.validate_release_identity(release, published) ? ReleaseCollision
		if published.draft or !GitHub.has_published_assets(published.assets, expected_assets) {
			Err(PublishedReleaseMismatch)
		} else {
			Ok({})
		}
	}
}
