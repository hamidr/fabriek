# shellcheck shell=bash
## Checking a value against a closed schema.
##
## cageworks reads two declarations it did not write: the factory a repository
## declares about itself (ADR-020) and the ceilings an operator sets. Both are
## closed, meaning a key nobody recognises is refused with its own name rather
## than ignored, and for the first of the two that is the whole argument that a
## repository cannot reach the machine it is given.
##
## The check lives here once rather than in each reader. Two implementations of
## "closed" would be free to drift, and the way they would drift is one of them
## quietly accepting what the other refuses.

## The jq definitions every schema check is written against.
##
## unknown is the whole of it: given an object, the keys the schema allows and
## a phrase saying where the reader is, it names what does not belong. A level
## is added to a schema by calling this once more rather than by inventing a
## new kind of check.
##
## cat flattens a list of problem lists, because a check that finds nothing
## returns an empty list and every level is a list of levels.
cageworks_schema_prelude() {
	cat <<'JQ'
def unknown($obj; $allowed; $where):
  if ($obj | type) == "object"
  then (($obj | keys_unsorted) - $allowed) | map("\($where): unknown key \(.)")
  else [] end;

def cat: reduce .[] as $each ([]; . + $each);
JQ
}

## Run a schema program over JSON on standard input, and report what it finds.
## The program is expected to emit one problem per line and nothing when the
## value is good, so that "is this valid" and "what is wrong with it" are the
## same question asked once.
cageworks_schema_check() {
	local program="$1" subject="${2:-input}" value problems
	value="$(cat)"

	if ! printf '%s' "$value" | jq -e . >/dev/null 2>&1; then
		echo "cageworks: the $subject is not valid JSON" >&2
		return 1
	fi

	problems="$(printf '%s' "$value" | jq -r "$(cageworks_schema_prelude)
$program")" || return 1

	if [ -n "$problems" ]; then
		while IFS= read -r problem; do
			echo "cageworks: $problem" >&2
		done <<<"$problems"
		return 1
	fi

	printf '%s\n' "$value"
}
