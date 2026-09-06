# shellcheck shell=bash
## What a factory asks of the machine it is given, and what the operator allows
## it (ADR-020 point 5).
##
## The repository states its needs and the operator caps them, so the same four
## fields are read by three different things: the schema that says what a
## declaration may name, the schema that says what an operator may cap, and the
## clamp that meets one against the other. They are one table here, so a field
## is added once rather than in three places that can disagree.
##
## Clamping is a function of two values and nothing else: the declaration on
## standard input and the ceilings in a file. It reads no config, so what it
## does is decided entirely by what it was given.

## What a factory may ask for, and how each is compared. A size is compared by
## magnitude and a count by number, which is the only difference between them.
cageworks_resource_fields() {
	printf '%s\t%s\n' \
		memory size \
		cores count \
		roleQuota size \
		concurrency count
}

## The same table as a JSON array, for the schemas that need to say which keys
## they allow.
cageworks_resource_field_names_json() {
	cageworks_resource_fields | cut -f1 | jq -Rrn '[inputs] | tojson'
}

## A declared value as a number that can be compared. A size becomes bytes; a
## count is already one. Anything else is a mistake in whichever declaration it
## came from, and is named rather than read as zero.
cageworks_resource_magnitude() {
	local kind="$1" value="$2" where="$3"
	case "$kind" in
	size)
		cageworks_size_bytes "$value" 2>/dev/null && return 0
		echo "cageworks: $where is not a size: $value" >&2
		return 1
		;;
	*)
		if [[ ! "$value" =~ ^[0-9]+$ ]]; then
			echo "cageworks: $where is not a count: $value" >&2
			return 1
		fi
		printf '%s\n' "$value"
		;;
	esac
}

## A declaration on standard input, clamped to the ceilings in the given file,
## on standard output. Each field the factory asked for that is above its
## ceiling comes back as the ceiling, and the operator is told which field was
## clamped and from what, rather than finding out from free(1).
##
## A field the factory did not ask for stays unasked: a ceiling is a limit
## rather than a default. A field the operator set no ceiling for is left as
## the factory asked for it, because a ceiling nobody set is not one.
cageworks_resources_clamp() {
	local caps_file="$1" declaration caps field kind asked ceiling asked_n ceiling_n
	declaration="$(cat)"

	if [ ! -f "$caps_file" ]; then
		echo "cageworks: no ceilings to clamp against: $caps_file" >&2
		return 1
	fi
	caps="$(cat "$caps_file")"

	while IFS=$'\t' read -r field kind; do
		asked="$(printf '%s' "$declaration" | jq -r --arg f "$field" '.resources[$f] // empty')"
		[ -n "$asked" ] || continue
		ceiling="$(printf '%s' "$caps" | jq -r --arg f "$field" '.[$f] // empty')"

		asked_n="$(cageworks_resource_magnitude "$kind" "$asked" "$field")" || return 1
		[ -n "$ceiling" ] || continue
		ceiling_n="$(cageworks_resource_magnitude "$kind" "$ceiling" "the ceiling for $field")" || return 1

		[ "$asked_n" -gt "$ceiling_n" ] || continue
		echo "cageworks: $field asked for $asked and this host allows $ceiling; clamped to $ceiling" >&2
		declaration="$(printf '%s' "$declaration" |
			jq --arg f "$field" --argjson v "$(printf '%s' "$caps" | jq --arg f "$field" '.[$f]')" \
				'.resources[$f] = $v')"
	done < <(cageworks_resource_fields)

	printf '%s\n' "$declaration"
}
