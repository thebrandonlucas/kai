# Release publisher entry point
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/${
		""
	}F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/${
		""
	}6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import PublishRelease

main! = |args|
	if args.len() == 1 {
		PublishRelease.run!()
	} else {
		Err(PublishReleaseArgumentsNotAllowed)
	}
