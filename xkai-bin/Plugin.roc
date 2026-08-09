# Pure plugin model shared by plugins and the CLI.
import Body

Plugin := [
	Module(
		{
			definition : Definition,
			plan : Str, List(Str), HostOs, HostArch -> Try(Plan, Error),
		},
	),
	Registry({ definition : Definition }),
].{
	Error : [InvalidConfig, UnknownCommand, UnsupportedPlatform]
	HostOs : [LINUX, MACOS, OTHER(Str)]
	HostArch : [X86, X64, ARM, AARCH64, OTHER(Str)]

	run : Plugin, Str, List(Str), HostOs, HostArch -> Try(Plan, Error)
	run = |plugin, config_text, args, os, arch|
		match plugin {
			Module({ definition: _, plan }) => plan(config_text, args, os, arch)
			Registry({ definition: _ }) => Err(UnknownCommand)
		}

	definition : Plugin -> Definition
	definition = |plugin|
		match plugin {
			Module({ definition, plan: _ }) => definition
			Registry({ definition }) => definition
		}

	# Side effects to be performed by a plugin.
	Action := [
		Exec({ args : List(Str), command : Str }),
		WriteUtf8({ content : Str, path : Str }),
	].{
		encoder_for : _
		parser_for : _
	}

	ActionTemplate : [
		Exec(
			{
				args : List(Str),
				command : Str,
			},
		),
		WriteConfigUtf8({ output : Str, path : Str }),
	]

	ArgumentPolicy : [AllowArguments, NoArguments]

	ConfigBlockRequirement : [OptionalConfigBlock(Str), RequiredConfigBlock(Str)]

	Command := {
		argument_policy : ArgumentPolicy,
		body : Body.Shape,
		config_block : ConfigBlockRequirement,
		default_backend : Str,
		name : Str,
	}

	DeterminateSystemKind : [Custom, Guix, Nix]

	DeterminateSystem := {
		default_package_source : Str,
		driver : [NoDriver, Program(Str)],
		kind : DeterminateSystemKind,
	}

	# Many packages are collections of programs, not
	# runnable binaries themselves.
	Package := {
		name : Str,
		program : Str,
	}

	# If the Backend doesn't have the right prerequisites
	# at runtime (for example, missing the chosen
	# DeterminateSystemKind or missing any other specified Package)
	# then we give a Fallback prompt to help them or advise.
	Fallback := {
		actions : List(Action),
		prompt : [DefaultPrompt, Prompt(Str)],
	}

	Backend := {
		determinate_system : DeterminateSystem,
		fallback : [Fallback(Fallback), NoFallback],
		name : Str,
		required_packages : List(Package),
	}

	SourceLocation := {
		byte_offset : U64,
		column : U64,
		line : U64,
	}

	LocatedConfigBlock := {
		body : Str,
		location : SourceLocation,
	}

	RenderContext := {
		args : List(Str),
		config : Body.Configuration,
		config_block : [NoConfigBlock, SelectedConfigBlock(LocatedConfigBlock)],
		host_arch : HostArch,
		host_os : HostOs,
	}

	# Text that will get written to disk.
	# "name" is what our plugin would name
	# the output internally, e.g. "flake",
	# the text is the actual text inside flake.nix
	RenderedOutput := {
		name : Str,
		text : Str,
	}

	RenderResult := {
		outputs : List(RenderedOutput),
		requested_packages : List(Str),
	}

	RendererDiagnostic := {
		byte_offset : [At(U64), None],
		message : Str,
	}

	Renderer : RenderContext -> Try(RenderResult, RendererDiagnostic)

	Implementation := {
		actions : List(ActionTemplate),
		backend : Str,
		command : Str,
		renderer : Renderer,
	}

	Definition := {
		backends : List(Backend),
		commands : List(Command),
		implementations : List(Implementation),
		name : Str,
	}

	Plan := {
		actions : List(Action),
	}.{
		encoder_for : _
		parser_for : _
	}

	# Lower pure action templates into a runtime plan.
	lower : Implementation, RenderResult -> Try(Plan, RendererDiagnostic)
	lower = |implementation, rendered| {
		actions = Plugin.lower_actions(
			implementation.actions,
			rendered.outputs,
		)?
		Ok(Plugin.Plan.{ actions })
	}

	lower_actions :
		List(ActionTemplate),
		List(RenderedOutput) ->
			Try(List(Action), RendererDiagnostic)
	lower_actions = |templates, outputs|
		match templates {
			[] => Ok([])
			[first, .. as rest] => {
				# At present there are two actions, Exec
				# and WriteConfigUtf8 (write a file).
				# For WriteConfigUtf8, we have a list of rendered
				# output files
				action = match first {
					Exec(exec) => Ok(Exec(exec))

					WriteConfigUtf8({ output, path }) =>
						match Plugin.find_output(outputs, output) {
							Ok(content) => Ok(WriteUtf8({ content, path }))
							Err(diagnostic) => Err(diagnostic)
						}
					}?
				rest_actions = Plugin.lower_actions(rest, outputs)?
				Ok([action].concat(rest_actions))
			}
		}

	find_output : List(RenderedOutput), Str -> Try(Str, RendererDiagnostic)
	find_output = |outputs, expected_name|
		match outputs {
			[] => Err({
				byte_offset: None,
				message: "plugin renderer did not return named output '${expected_name}'",
			})
			[first, .. as rest] =>
				if first.name == expected_name {
					Ok(first.text)
				} else {
					Plugin.find_output(rest, expected_name)
				}
			}
}
