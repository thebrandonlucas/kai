# kai's one question to a compiled Kaifile and its answer, as S-expressions.
import Layout
import Plan
import Sexpr

Protocol := [].{
	Version : { major : U64, minor : U64 }

	current : Version
	current = { major: 1, minor: 0 }

	## `argv` is kai's argv without argv[0].
	Request := {
		protocol : Version,
		argv : List(Str),
		style : [Color, Plain],
		host : { system : Str },
		layout : Layout,
		lock : [Absent, Present(Str)],
		resume : [
			Fresh,
			Resume(
				{
					command : Str,
					backend : Str,
					phase : U64,
					observed : List({ path : Str, contents : [Missing, Text(Str)] }),
				},
			),
		],
	}.{
		is_eq : _

		encoder_for : _

		parser_for : _
	}

	## Every response names its protocol and platform release (`platform` on
	## the wire), so kai can refuse before decoding `body`.
	Response := { protocol : Version, platform_ : Str, body : Body }.{
		is_eq : _

		encoder_for : _

		parser_for : _
	}

	## `Candidates` holds one option per backend implementing `command`, in
	## preference order; exactly one when answering a `Resume`.
	Body := [
		Help(Str),
		Usage(Str),
		Describe(Manifest),
		Candidates(
			{
				command : Str,
				plugin : Str,
				choice : [Auto, Only(Str)],
				options : List(Candidate),
			},
		),
		Refused(Str),
	].{
		is_eq : _

		encoder_for : _

		parser_for : _
	}

	## `backend` is "" for an implementation that needs none.
	Candidate : {
		backend : Str,
		plugin : Str,
		probes : List(
			{ program : Str, flag : [DoubleDashVersion, DashV, VersionWord] },
		),
		outcome : [Unfit(Str), Planned(Plan), Failed(Str)],
	}

	## Placeholder until the Kaifile's validated description is designed.
	Manifest := {
		plugins : List({ name : Str, version : Str }),
		commands : List(Str),
		backends : List(Str),
	}.{
		is_eq : _

		encoder_for : _

		parser_for : _
	}

	## Refuses another major or a newer minor before decoding the rest.
	decode_response :
		Str ->
			Try(
				Response,
				[InvalidSexpr(Str), MissingRequiredField(Str), Incompatible(Version)],
			)
	decode_response = |text| {
		header : { protocol : Version }
		header = Sexpr.parse(text)?
		version = header.protocol
		if version.major != current.major or version.minor > current.minor {
			return Err(Incompatible(version))
		}
		Sexpr.parse(text)
	}
}

request : Protocol.Request
request = Protocol.Request.{
	protocol: Protocol.current,
	argv: [],
	style: Plain,
	host: { system: "x86_64-linux" },
	layout: Layout.{
		project_root: "/p",
		workspace: "/p/.kai",
		generated_root: "/p/.kai/generated",
		lock_path: "/p/.kai/lock.json",
	},
	lock: Absent,
	resume: Fresh,
}

response : Protocol.Body -> Protocol.Response
response = |body|
	Protocol.Response.{ protocol: Protocol.current, platform_: "0.0.8", body }

planned : Protocol.Candidate
planned = {
	backend: "nix",
	plugin: "std",
	probes: [{ program: "nix", flag: DoubleDashVersion }],
	outcome: Planned(Plan.{ steps: [Note("hi")], next: Done }),
}

# Requests round-trip, including option-looking argv and awkward strings.
expect [
	request,
	{ ..request, argv: ["--", "-x", "--backend=nix", ""], style: Color },
	{
		..request,
		lock: Present("{\n\t\"a\": \"b\\\"\"\n}"),
		resume: Resume({
			command: "update",
			backend: "nix",
			phase: 1,
			observed: [
				{ path: "/a", contents: Missing },
				{ path: "/b", contents: Text("x\ny") },
			],
		}),
	},
]
	.all(|r| Sexpr.parse(Sexpr.to_str(r)) == Ok(r))

candidates : Protocol.Body
candidates = Candidates({
	command: "shell",
	plugin: "std",
	choice: Only("nix"),
	options: [
		{ backend: "guix", plugin: "std", probes: [], outcome: Unfit("overlays") },
		planned,
		{ backend: "", plugin: "x", probes: [], outcome: Failed("no") },
	],
})

# Each body round-trips through decode_response.
expect [
	Help("usage:\n  kai"),
	Usage("\"x\" unknown"),
	Describe(
		Protocol.Manifest.{
			plugins: [{ name: "std", version: "0.0.8" }],
			commands: ["shell"],
			backends: ["nix"],
		},
	),
	Refused("--backend must be one of nix, guix"),
	candidates,
]
	.map(response)
	.all(|r| Protocol.decode_response(Sexpr.to_str(r)) == Ok(r))

# The release is `platform` on the wire; unknown steps, newer minors and other
# majors are refused.
expect {
	text = Sexpr.to_str(response(candidates))
	text.contains("(platform \"0.0.8\")") and [
		(text.replace_each("(Note ", "(Delete "), Bool.False),
		(text.replace_each("(minor 0)", "(minor 1)"), Bool.True),
		(text.replace_each("(major 1)", "(major 2)"), Bool.True),
		(text.replace_each("(major 1)", "(major 0)"), Bool.True),
	]
		.all(
			|(bad, incompatible)|
				match Protocol.decode_response(bad) {
					Err(Incompatible(_)) => incompatible
					Err(InvalidSexpr(_)) => !incompatible
					_ => Bool.False
				},
		)
}
