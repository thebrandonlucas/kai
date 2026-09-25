# Build each roc-fuzz target with coverage instrumentation and run it for a
# while from its seed corpus. A crash or hang fails, and libFuzzer saves the
# input under zig-out/fuzz. Inputs it finds stay out of the repository.
import pf.Cmd
import pf.Path
import pf.Stderr
import pf.Stdout

Fuzz := [].{
	run! = |seconds, apps| {
		Path.create_all!(Path.utf8("zig-out/fuzz"))?
		for source in apps {
			Fuzz.target!(seconds, source)?
		}
		Ok({})
	}

	# `kaifile/ir/fuzz/parse/main.roc` is `ir-parse`.
	target_name = |source|
		match source.split_on("/") {
			[.., owner, "fuzz", target, "main.roc"] => "${owner}-${target}"
			_ => source
		}

	target! = |seconds, source| {
		name = Fuzz.target_name(source)
		dir = source.drop_suffix("main.roc")
		out = "zig-out/fuzz/${name}"
		# A build with type errors still emits a binary but exits 1; roc-fuzz's
		# own Roc pin warns, which exits 2. Accept warnings, never errors.
		# --no-cache: https://github.com/roc-lang/roc/issues/11673
		built = Cmd.new_str("roc")
			.args_str(["build", "--no-cache", "--fuzz", source, "--output=${out}"])
			.merge_stderr(Bool.True)
			.run!()?
		match built.status {
			Exited(0) | Exited(2) => {}
			_ => {
				Stderr.write_bytes!(built.stdout_bytes)?
				return Err(FuzzBuildFailed(source))
			}
		}
		# New inputs go to the first, writable corpus; the seeds stay intact.
		corpus = "${out}-corpus"
		Path.create_all!(Path.utf8(corpus))?
		entries = Path.list!(Path.utf8(dir))?.map(Path.display)
		dicts = entries
			.keep_if(|path| path.ends_with(".dict"))
			.map(|path| "-dict=${path}")
		seeds = entries.keep_if(|path| path.ends_with("/corpus"))
		Stdout.line!("==> ${name} (${seconds}s)")?
		fuzzed = Cmd.new_str(out)
			.args_str(
				[
					"-max_total_time=${seconds}",
					"-timeout=10",
					"-print_final_stats=1",
					"-artifact_prefix=${out}-",
				]
					.concat(dicts)
					.concat([corpus])
					.concat(seeds),
			)
			.merge_stderr(Bool.True)
			.output_limit(268435456)
			.run!()?
		log = Str.from_utf8_lossy(fuzzed.stdout_bytes)
		Path.write_utf8!(Path.utf8("${out}.log"), log)?
		lines = log.split_on("\n")
		if fuzzed.status != Exited(0) {
			Stderr.line!(Str.join_with(lines.take_last(40), "\n"))?
			return Err(FuzzTargetFailed({ name, input: "${out}-*", log: "${out}.log" }))
		}
		for line in lines.keep_if(|line| line.starts_with("Done")) {
			Stdout.line!(line)?
		}
		Ok({})
	}
}
