- The architecture is inspired by [Caddy](https://caddyserver.com/docs/architecture). The DSL is simple, like that in `Caddyfile`:
```kai
shell nix {
    pkgs: ["cowsay", "fortune"]
}
```
When called by the `kai` CLI, this `config.kai` file produces backend runtime output such as `.kai/flake.nix`, then calls `nix develop` to enter that shell. `.kai` contains backend output only; plugin source and compiler inputs do not persist there. Kai supplies assumed defaults where Nix is more explicit.
- Kai uses Caddy-like [modularity](https://caddyserver.com/docs/architecture) and aspires to Unix philosophy. There is a standard plugin and users can write custom plugins which augment or replace standard plugin commands via a registry where each plugin must supply generic commands, a "backend" to run on (i.e. `nix` or `guix`) and implementations which connect the two. This setup is powerful, as it allows users to swap commands or add their own. Eventually this could even mean that certain painful parts of `nix` can be rewritten (such as the famously slow evaluator) while the rest of `kai` still uses `nix` under the hood!
- [Work in small steps to stay motivated](https://mitchellh.com/writing/building-large-technical-projects). Avoid big changes where possible.
- If the programmer tells you to implement a concept, do the minimal amount of work to prove the concept while still following the rules and design philosophy (for example, you may still add a simple test or two).
- Aspirational dependency culture: vendored, like Roc or Ghostty.
- Aspirational software philosophy: Loosened Tigerbeetle's [tigerstyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md), particularly:
    - "An hour or day of design is worth weeks or months in production:
    - "the simple and elegant systems tend to be easier and faster to design and get right, more efficient in execution, and much more reliable" — Edsger Dijkstra"
    - "What could go wrong? What's wrong? Which question would we rather ask? The former, because code, like steel, is less expensive to change while it's hot. A problem solved in production is many times more expensive than a problem solved in implementation, or a problem solved in design"
    - "We know that what we ship is solid. We may lack crucial features, but what we have meets our design goals. This is the only way to make steady incremental progress, knowing that the progress we have made is indeed progress."
- From [Boundaries](https://www.destroyallsoftware.com/talks/boundaries): separate the pure data from side-effects. This makes programs much more predictable and testable. Example from `kai`: `Plugin`s are written as pure data describing which effects to perform, so that we can test the expected results, then an executor actually writes files or calls external commands like `nix`. But the validation happens inside.
- Style: This repo aspires to the rules set out in [clig.dev](https://clig.dev/)

## Tests
- Rules from matklad's [How to Test](https://matklad.github.io/2021/05/31/how-to-test.html) (Thank you [matklad](https://matklad.github.io/)!):
    - Avoid test ossification. Design tests such that changes to code do not require changes to tests when possible. Example from link:

Instead of this:
```rust
/// Given a *sorted* `haystack`, returns `true`
/// if it contains the `needle`.
fn binary_search(haystack: &[T], needle: &T) -> bool {
    ...
}

#[test]
fn binary_search_empty() {
  let res = binary_search(&[], &0);
  assert_eq!(res, false);
}

#[test]
fn binary_search_singleton() {
  let res = binary_search(&[92], &0);
  assert_eq!(res, false);

  let res = binary_search(&[92], &92);
  assert_eq!(res, true);

  let res = binary_search(&[92], &100);
  assert_eq!(res, false);
}

// And a dozen more of other similar tests...
```

Which requires a change to the code necessitating a refactor of every test, what if you wrote a `check` function which would allow you to simply think about the _data_ that is getting passed into that test instead? That way you can think more about the data itself, expected inputs and outputs, and any nuances or API changes to the function can be updated in that one place!
```rust
#[track_caller]
fn check(
  input_haystack: &[i32],
  input_needle: i32,
  expected_result: bool,
i) {
  // As long as the shape of the data itself doesn't 
  // change, we only need to update the api here when it changes.
  // cheap refactor!
  let actual_result =
    binary_search(input_haystack, &input_needle);
  assert_eq!(expected_result, actual_result);
}

#[test]
fn binary_search_empty() {
  check(&[], 0, false);
}

#[test]
fn binary_search_singleton() {
  check(&[92], 0, false);
  check(&[92], 92, true);
  check(&[92], 100, false);
}
```

- Test the features of the code (think high-level about the data as opposed to low level about the code itself, and write the tests around that).
- Make tests mentally frictionless and fast when possible (try to test functions purely and predictably so that you don't have to deal with the mental and physical costs of side-effects).
- i.e., [data driven testing](https://matklad.github.io/2021/05/31/how-to-test.html#Data-Driven-Testing).
