# Mutate .kai/lock.json text without requiring a resolvable lock.
app [target] {
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst",
	nix: "../../main.roc",
}

import pf.Fuzz
import nix.LockJson
import nix.Locks

## `LockJson.decode` and `Locks.decode` must return a result, never crash or
## hang, for any text; and whatever they accept must re-encode to text that
## decodes to the same value.
##
## The input is raw bytes read as UTF-8, so the seeds in `corpus/` are plain
## lock files the fuzzer can mutate directly.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			match LockJson.decode(text) {
				Ok(json) =>
					if LockJson.decode(LockJson.encode(json)) != Ok(json) {
						crash "accepted lock JSON did not survive a re-encode"
					}
				Err(_) => {}
			}
			match Locks.decode(text) {
				Ok(locks) =>
					if Locks.decode(Locks.encode(locks)) != Ok(locks) {
						crash "accepted lock did not survive a re-encode"
					}
				Err(_) => {}
			}
			Fuzz.keep
		}
	}

target = Fuzz.target_with({
	name: "nix-lock",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
