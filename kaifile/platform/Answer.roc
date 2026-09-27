# The Kaifile's one answer to kai's request: help, a usage error, a refusal,
# or the candidate plans for the command kai was asked to run.
import Argv
import Command
import Kaifile
import Protocol
import Sexpr

Answer := [].{

	## kai's own page, above every plugin command.
	kai : Command.Page
	kai = {
		description: "Developer environments, tasks and builds from a Kaifile.roc.",
		examples: ["kai check", "kai update", "kai shell", "kai run test"],
		config: [
			"Environment(\"dev\", [Tools([\"git\"])]),",
			"Shell(\"default\", [Use(\"dev\")]),",
			"Task(\"test\", [Use(\"dev\"), Run([\"git\", \"--version\"])]),",
		],
	}

	## kai runs `check` itself, even when Kaifile.roc does not compile; it is
	## listed here so help shows it.
	check : Command
	check = Command.{
		name: "check",
		summary: "Compile Kaifile.roc and report whether its configuration is valid.",
		help: {
			description: "Compile Kaifile.roc and report whether its configuration is "
				.concat("valid, without building or running anything."),
			examples: [
				"kai check",
				"kai --file Kaifile.roc check",
				"kai --json check",
			],
			config: [],
		},
		args: [],
		lock: ReadsLock,
	}

	body : Kaifile, Protocol.Request -> Protocol.Body
	body = |kaifile, request| {
		commands = [Answer.check].concat(kaifile.plugins.join_map(|p| p.commands))
		match Argv.parse(Answer.kai, commands, request.style, request.argv) {
			Err(Help(text)) => Help(text)
			Err(Usage(text)) => Usage(text)
			Ok({ command: "check", .. }) => Refused("kai checks Kaifile.roc itself")
			Ok({ globals, command, args }) => {
				(choice, phase, observed) = match request.resume {
					Fresh =>
						match globals.backend {
							Ok(backend) => (Only(backend), 0, [])
							Err(NoValue) => (Auto, 0, [])
						}
					Resume(resumed) => (Only(resumed.backend), resumed.phase, resumed.observed)
				}
				Kaifile.candidates(
					kaifile,
					command,
					choice,
					|backend| {
						args,
						backend,
						host: request.host,
						layout: request.layout,
						lock: request.lock,
						phase,
						observed,
					},
				)
			}
		}
	}

	## The response to kai's request text: refused before anything else when
	## it cannot be read or speaks another protocol version.
	respond : Kaifile, Str -> Str
	respond = |kaifile, text| {
		header : Try({ protocol : Protocol.Version }, _)
		header = Sexpr.parse(text)
		refused = |why|
			Protocol.Response.{
				protocol: Protocol.current,
				platform_: "",
				body: Refused(why),
			}
		response = match header {
			Ok({ protocol }) if protocol.major != Protocol.current.major
				or protocol.minor > Protocol.current.minor =>
				refused(
					"kai speaks protocol ${protocol.major.to_str()}."
						.concat(protocol.minor.to_str()),
				)
			Ok(_) => {
				request : Try(Protocol.Request, _)
				request = Sexpr.parse(text)
				match request {
					Ok(r) =>
						Protocol.Response.{
							protocol: Protocol.current,
							platform_: "",
							body: Answer.body(kaifile, r),
						}
					Err(err) => refused("cannot read kai's request: ${Str.inspect(err)}")
				}
			}
			Err(err) => refused("cannot read kai's request: ${Str.inspect(err)}")
		}
		Sexpr.to_str(response)
	}
}
