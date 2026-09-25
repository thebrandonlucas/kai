# Mutate wire text without requiring a semantically valid project.
app [target] {
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst",
	ir: "../../main.roc",
}

import pf.Fuzz
import ir.Ir
import ir.Project

## `Ir.parse` must return a result, never crash or hang, for any text; and
## whatever it accepts must re-encode to text that parses to the same IR.
##
## The input is raw bytes read as UTF-8, so the seeds in `corpus/` are plain
## IR text the fuzzer can mutate directly.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) =>
			match Ir.parse(text) {
				Ok(ir) => {
					if Ir.parse(ir.to_str()) != Ok(ir) {
						crash "accepted IR did not survive a re-encode"
					}
					match Project.validate(ir) {
						Ok(project) => {
							if Project.validate(project) != Ok(project)
								or Ir.parse(project.to_str()) != Ok(project) {
								crash "semantic normalization is not idempotent"
							}
							# Exercise one root without revalidating every root per input.
							for workflow in project.workflows.take_first(1) {
								match Project.workflow_steps(project, workflow.name) {
									Ok(steps) => if steps.len() > 4096 {
										crash "workflow expansion escaped its bound"
									}
									Err(_) => crash "validated workflow failed expansion"
								}
							}
						}
						Err(_) => {}
					}
					Fuzz.keep
				}
				Err(_) => Fuzz.keep
			}
		}

target = Fuzz.target_with({
	name: "ir-parse",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
