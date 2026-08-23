# Pure GitHub release publication state and JSON models.
import Release

GitHub := [].{
	ExpectedAsset : { digest : Str, name : Str }
	Asset : { digest : Try(Str, [Null]), id : U64, name : Str, state : Str }
	RemoteRelease : {
		assets : List(Asset),
		draft : Bool,
		id : U64,
		name : Try(Str, [Null]),
		prerelease : Bool,
		tag_name : Str,
		upload_url : Str,
	}
	PublicationState : {
		release : [FoundRelease(RemoteRelease), NoRelease],
		tag : [AnnotatedTag({ name : Str, target_commit : Str }), LightweightTag(Str), NoTag],
	}
	Decision : [
		AlreadyPublished,
		CreateDraft,
		ResumeDraft({ assets : List(Asset), id : U64, upload_url : Str }),
		StartFresh,
	]
	Collision : [
		LocalAssetsMismatch({ actual : List(ExpectedAsset), expected : List(Str) }),
		PublishedAssetsMismatch({ actual : List(Asset), expected : List(ExpectedAsset) }),
		ReleaseNameMismatch,
		ReleasePrereleaseMismatch,
		ReleaseTagMismatch({ actual : Str, expected : Str }),
		ReleaseWithoutTag,
		TagAnnotationMismatch({ actual : Str, expected : Str }),
		TagTargetMismatch({ actual : Str, expected : Str }),
		UnexpectedLightweightTag,
	]
	CreateReleaseRequest : {
		draft : Bool,
		generate_release_notes : Bool,
		name : Str,
		prerelease : Bool,
		tag_name : Str,
		target_commitish : Str,
	}

	validate_release_identity : Release.MergedRelease, RemoteRelease -> Try({}, Collision)
	validate_release_identity = |release, remote|
		if remote.tag_name != release.tag_name {
			Err(ReleaseTagMismatch({ actual: remote.tag_name, expected: release.tag_name }))
		} else if remote.name != Ok(release.name) {
			Err(ReleaseNameMismatch)
		} else if remote.prerelease {
			Err(ReleasePrereleaseMismatch)
		} else {
			Ok({})
		}

	has_published_assets = |assets, expected|
		assets.len() == expected.len() and List.all(
			expected,
			|wanted|
				List.any(
					assets,
					|asset|
						asset.name == wanted.name and
							asset.digest == Ok(wanted.digest) and
								asset.state == "uploaded",
				),
		)

	decide : Release.MergedRelease, List(ExpectedAsset), PublicationState -> Try(Decision, Collision)
	decide = |release, expected_assets, state| {
		expected_names = expected_assets.map(|asset| asset.name)
		if !Release.is_exact_inventory(expected_names, release.assets) {
			Err(LocalAssetsMismatch({ actual: expected_assets, expected: release.assets }))
		} else {
			match (state.tag, state.release) {
				(NoTag, NoRelease) => Ok(StartFresh)
				(NoTag, FoundRelease(_)) => Err(ReleaseWithoutTag)
				(LightweightTag(_), _) => Err(UnexpectedLightweightTag)
				(AnnotatedTag(tag), _) if tag.target_commit != release.target_commit =>
					Err(TagTargetMismatch({ actual: tag.target_commit, expected: release.target_commit }))
				(AnnotatedTag(tag), _) if tag.name != release.name =>
					Err(TagAnnotationMismatch({ actual: tag.name, expected: release.name }))
				(AnnotatedTag(_), NoRelease) => Ok(CreateDraft)
				(AnnotatedTag(_), FoundRelease(remote)) => {
					GitHub.validate_release_identity(release, remote)?
					if remote.draft {
						Ok(ResumeDraft({ assets: remote.assets, id: remote.id, upload_url: remote.upload_url }))
					} else if GitHub.has_published_assets(remote.assets, expected_assets) {
						Ok(AlreadyPublished)
					} else {
						Err(PublishedAssetsMismatch({ actual: remote.assets, expected: expected_assets }))
					}
				}
			}
		}
	}

	create_release_request : Release.MergedRelease -> CreateReleaseRequest
	create_release_request = |release| {
		draft: Bool.True,
		generate_release_notes: Bool.True,
		name: release.name,
		prerelease: Bool.False,
		tag_name: release.tag_name,
		target_commitish: release.target_commit,
	}

	create_release_json : Release.MergedRelease -> Str
	create_release_json = |release| Json.to_str(GitHub.create_release_request(release))

	publish_release_json : Str
	publish_release_json = Json.to_str({ draft: Bool.False })

	decode_release : Str -> Try(RemoteRelease, [InvalidReleaseJson])
	decode_release = |input| {
		decoded = Json.parse(input)
		match decoded {
			Ok(release) => Ok(release)
			Err(_) => Err(InvalidReleaseJson)
		}
	}
}

## -- TESTS --

release = {
	assets: ["SHA256SUMS", "kai-0.0.3-aarch64-linux.tar.gz", "kai-0.0.3-x86_64-linux.tar.gz"],
	name: "μοριων \"blue\" \\ path 🚀",
	tag_name: "v0.0.3",
	target_commit: "0123456789abcdef0123456789abcdef01234567",
	version: "0.0.3",
}

expected_assets = [
	{ digest: "sha256:aaa", name: "SHA256SUMS" },
	{ digest: "sha256:bbb", name: "kai-0.0.3-aarch64-linux.tar.gz" },
	{ digest: "sha256:ccc", name: "kai-0.0.3-x86_64-linux.tar.gz" },
]

uploaded_assets = [
	{ digest: Ok("sha256:aaa"), id: 1, name: "SHA256SUMS", state: "uploaded" },
	{ digest: Ok("sha256:bbb"), id: 2, name: "kai-0.0.3-aarch64-linux.tar.gz", state: "uploaded" },
	{ digest: Ok("sha256:ccc"), id: 3, name: "kai-0.0.3-x86_64-linux.tar.gz", state: "uploaded" },
]

remote = {
	assets: uploaded_assets,
	draft: Bool.True,
	id: 42,
	name: Ok(release.name),
	prerelease: Bool.False,
	tag_name: release.tag_name,
	upload_url: "https://uploads.github.test/releases/42/assets{?name,label}",
}

matching_tag = AnnotatedTag({ name: release.name, target_commit: release.target_commit })
