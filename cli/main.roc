# kai: developer environments, tasks and builds from a Kaifile.roc.
#
# Transitional entry point for the native Roc Kaifile; it replaces the xkai
# CLI once it covers the supported commands.
app [main!] {
	pf: platform "../.basic-cli/main.roc",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/${
		""
	}0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	ir: "../kaifile/ir/main.roc",
	nix: "../kaifile/nix/main.roc",
}

import pf.Env
import pf.OsStr
import pf.Stderr
import pf.Stdout
import weaver.Cli
import weaver.Opt
import weaver.SubCmd
import ir.Ir

import Load

version = "0.0.7"

Command : [Check, PrintIr]

parser = |text_style|
	Cli.assert_valid(
		Cli.finish(
			{
				file: Opt.maybe_str({
					short: "f",
					long: "file",
					help: "Read configuration from PATH (default: Kaifile.roc).",
				}),
				command: SubCmd.required([
					SubCmd.empty({
						name: "check",
						description: "Validate Kaifile.roc with the Roc compiler",
						value: Check,
					}),
					SubCmd.empty({
						name: "ir",
						description: "Print the validated Kaifile IR",
						value: PrintIr,
					}),
				]),
			}.Cli,
			{
				name: "kai",
				version,
				authors: [],
				description: \\Developer environments, tasks and builds from a Kaifile.roc.
					\\
					\\Set ROC to choose the Roc compiler (default: roc).
				,
				text_style,
			},
		),
	)

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	text_style = match Env.var_str!("NO_COLOR") {
		Ok(value) if !value.is_empty() => Plain
		_ => Color
	}
	match Cli.parse_or_display_message(parser(text_style), args, OsStr.to_raw) {
		Err(Help(message)) | Err(Version(message)) =>
			Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Ok({ file, command }) =>
			match run!(file, command) {
				Ok({}) => Ok({})
				Err(err) => {
					_ = Stderr.line!("kai: ${describe(err)}")
					Err(Exit(1))
				}
			}
		}
}

run! = |file, command| {
	project = Load.project!(file)?
	match command {
		Check => {
			Load.check!(project)?
			_ = Load.ir!(project)?
			Stdout.line!("${project.file} is valid")
		}
		PrintIr => Stdout.write!(Load.ir!(project)?.to_str())
	}
}

describe : _ -> Str
describe = |err|
	match err {
		NoKaifile(location) => "no Kaifile.roc at ${location}"
		UnsupportedHost =>
			"evaluating Kaifile.roc currently requires an x86_64 Linux host"
		CompilerUnavailable(compiler, message) =>
			"could not run the Roc compiler `${compiler}`; install the pinned "
				.concat("compiler or set ROC to it:\n${message}")
		CompilerMismatch(compiler, actual) =>
			"`${compiler}` is ${actual}; Kai needs the pinned Roc compiler"
		KaifileInvalid(file) => "${file} did not compile; see the errors above"
		KaifileFailed(file, output) => "${file} did not compile:\n${output}"
		BadIr(UnsupportedFormat({ major, minor })) =>
			"Kaifile IR ${U64.to_str(major)}.${U64.to_str(minor)} is not supported; "
				.concat("this kai reads major ${Ir.current_format.major.to_str()}")
		BadIr(reason) => "could not read the Kaifile IR: ${Str.inspect(reason)}"
		NeedsFeatures(missing) =>
			"Kaifile.roc needs unsupported features: "
				.concat(Str.join_with(missing, ", "))
		InvalidProject(message) => "invalid Kaifile: ${message}"
		other => Str.inspect(other)
	}
