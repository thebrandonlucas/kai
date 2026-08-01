# Friendly Kai configuration and its pure lowering pipeline.
Kai := [].{
	Config : {
		shell : {
			pkgs : List(Str),
		},
	}

	render : Config -> Try(
		Str,
		[InvalidConfig],
	)
	render = |config| {
		_valid = validate(config)?

		# Generically turn it into the backend string of choice.
		# For Nix, this is a flake.nix.
		# For Guix, this is a future backend format.
		Ok("im a flake")
	}

	# TODO: add specific validation errors as validation rules are introduced.
	validate : Config -> Try(Config, [InvalidConfig])
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
