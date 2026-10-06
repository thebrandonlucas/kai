# Release publisher entry point
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/${
		""
	}6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import PublishRelease

main! = |args|
	if args.is_empty() {
		PublishRelease.run!()
	} else {
		Err(PublishReleaseArgumentsNotAllowed)
	}
