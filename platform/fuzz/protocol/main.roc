# Mutate protocol text in both directions without requiring a sensible exchange.
app [target] {
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst",
	api: "../../api.roc",
}

import pf.Fuzz
import api.Protocol
import api.Sexpr

## Decoding a request or a response must return a result, never crash or
## hang, for any text; whatever it accepts must re-encode to text that decodes
## to the same value.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			match Protocol.decode_response(text) {
				Ok(response) =>
					if Protocol.decode_response(Sexpr.to_str(response)) != Ok(response) {
						crash "accepted response did not survive a re-encode"
					}
				Err(_) => {}
			}
			request : Try(Protocol.Request, _)
			request = Sexpr.parse(text)
			match request {
				Ok(r) =>
					if Sexpr.parse(Sexpr.to_str(r)) != Ok(r) {
						crash "accepted request did not survive a re-encode"
					}
				Err(_) => {}
			}
			Fuzz.keep
		}
	}

target = Fuzz.target_with({
	name: "platform-protocol",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
