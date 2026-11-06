# Ported from roc-blueprint's blueprint-core/Lookup.roc: Copyright © 2026
# Luke Boswell and subsequent authors, under the Universal Permissive
# License (UPL), Version 1.0 (see LICENSE).
#
## Values by text key, sorted for binary search: the identifier indexes of the
## SPDX validators and reader. It stands in for a `Dict`: in the bundled SBOM
## app, `roc run` reusing cached dev-backend objects for these modules made
## `Dict.contains` miss keys just inserted (nightly-2026-10-18-1df370f and
## nightly-2026-10-20-7a8a800, on Linux and macOS alike; roc-lang/roc#12495).
Lookup := [].{
	Entry(v) : { key : Str, value : v }

	## Order by UTF-8 bytes, for declaration-order-independent output.
	bytewise : Str, Str -> [Before, Same, After]
	bytewise = |a, b| {
		left = a.to_utf8()
		right = b.to_utf8()
		var $i = 0
		while $i < left.len() and $i < right.len() {
			l = left.get($i) ?? 0
			r = right.get($i) ?? 0
			if l < r {
				return Before
			}
			if l > r {
				return After
			}
			$i = $i + 1
		}
		if (
			left.len() < right
				.len()
		) Before else if (
			left
				.len() > right
				.len()
		) After else Same
	}

	## The entries sorted by key. For a key with several entries `find`
	## returns one of them; `repeated` names those keys.
	index : List(Lookup.Entry(v)) -> List(Lookup.Entry(v))
	index = |entries| entries.sort_with(|a, b| Lookup.bytewise(a.key, b.key))

	find : List(Lookup.Entry(v)), Str -> Try(v, [Missing])
	find = |sorted, key| {
		var $low = 0.U64
		var $high = sorted.len()
		while $low < $high {
			middle = $low + ($high - $low) // 2
			match sorted.get(middle) {
				Ok(entry) =>
					match Lookup.bytewise(entry.key, key) {
						Before => {
							$low = middle + 1
						}
						After => {
							$high = middle
						}
						Same => return Ok(entry.value)
					}
				Err(_) => return Err(Missing)
			}
		}
		Err(Missing)
	}

	contains : List(Lookup.Entry(v)), Str -> Bool
	contains = |sorted, key| Lookup.find(sorted, key).is_ok()

	## The keys an index holds more than once.
	repeated : List(Lookup.Entry(v)) -> List(Str)
	repeated = |sorted| {
		var $found = []
		var $previous = Err(Missing)
		for entry in sorted {
			if $previous == Ok(entry.key) and !$found.contains(entry.key) {
				$found = $found.append(entry.key)
			}
			$previous = Ok(entry.key)
		}
		$found
	}
}

sample = Lookup.index([
	{ key: "b", value: 2 },
	{ key: "a", value: 1 },
	{ key: "c", value: 3 },
	{ key: "b", value: 4 },
])

# find returns the value of a key.
expect Lookup.find(sample, "a") == Ok(1)
# find finds the last key.
expect Lookup.find(sample, "c") == Ok(3)
# A repeated key finds one of its values.
expect Lookup.find(sample, "b") == Ok(2) or Lookup.find(sample, "b") == Ok(4)
# An absent key, the empty key and an empty index find nothing.
expect Lookup.find(sample, "d").is_err() and
	Lookup.find(sample, "").is_err() and
		Lookup.find(
			[],
			"a",
		).is_err()
# repeated names keys indexed more than once.
expect Lookup.repeated(sample) == ["b"] and Lookup.repeated(
	Lookup.index([
		{
			key: "x",
			value: 0,
		},
	]),
) == []
# find finds every key of a large index.
expect {
	keys = List.repeat("k", 300).fold(
		[],
		|all, _| all.append("k${all.len().to_str()}"),
	)
	index = Lookup.index(keys.map(|key| { key, value: key }))
	keys.all(|key| Lookup.find(index, key) == Ok(key)) and !Lookup.contains(
		index,
		"k300",
	)
}
