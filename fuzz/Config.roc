app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst",
	parser: "../xkai/parser/main.roc",
}

import fuzz.Fuzz
import parser.Config

test : Str -> Fuzz.Outcome
test = |input| {
	_ = Config.scan(input)
	Fuzz.keep
}

target = Fuzz.target_with({
	name: "kai-config-robustness",
	generator: Fuzz.str,
	test,
	show: |input| Str.inspect(input),
})
