# Friendly Kai configuration and its pure lowering pipeline.
Kai := [].{
	Config : {
		shell : {
			pkgs : List(Str),
		},
	}

	render : Config -> Try(
		Str,
		[],
	)
	render = |config| {
		match validate(config) {
			Ok(_valid) => "sample str response"
			Err => []
		}
		# generically turn it into the backend string of choice
		# for nix, this is a flake.nix 
		# for guix, this is a ..?
	}

	# TODO: second param of Config will be ValidationError
	validate : Config -> Try(Config, _)
	validate = |config|
		Ok(config)
}

# .exec
expect {
	config = {
		shell: {
			pkgs: ["abc"],
		},
	}
	Kai.render(config)? == "im a flake"
}
