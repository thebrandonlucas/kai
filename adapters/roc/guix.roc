app [main!] { kai: platform "../../platform/main.roc" }

import kai.Adapter

main! : List(Str) => I32
main! = |args| Adapter.main!(args, Adapter.guixShell)
