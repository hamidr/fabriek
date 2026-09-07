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
## magnitude, a count by number, and a set by what it has in common with its
## ceiling. The last one is a permission rather than an amount, and it is in
## this table for the same reason the others are: so that a field cannot exist
## for a declaration and not for the operator.
cageworks_resource_fields() {
	printf '%s\t%s\n' \
		memory size \
		cores count \
		roleQuota size \
		journalQuota size \
		concurrency count \
		taskAttempts count \
		runTimeoutSeconds count \
		egress set
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
		if [ "$kind" = set ]; then
			declaration="$(printf '%s' "$declaration" |
				cageworks_resources_intersect "$field" "$caps")" || return 1
			continue
		fi

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

## A set field met against its ceiling: what the factory asked for, kept only
## where the operator allows it. Declaration on standard input, the same
## declaration out.
##
## This is where a set stops behaving like a size. A field with no ceiling is
## left as the factory asked for it, because a ceiling nobody set is not one --
## true of memory, and the wrong default for a permission. An operator who has
## named no endpoints has not thereby allowed every endpoint, so the empty
## ceiling is empty rather than absent, and a factory that declares an
## endpoint on a host whose operator has said nothing reaches nothing.
##
## A factory that asked for nothing is left asking for nothing either way: a
## ceiling is a limit and never a default.
cageworks_resources_intersect() {
	local field="$1" caps_file_json="$2" declaration asked allowed kept dropped
	declaration="$(cat)"

	asked="$(printf '%s' "$declaration" | jq -c --arg f "$field" '.resources[$f] // empty')"
	[ -n "$asked" ] || {
		printf '%s\n' "$declaration"
		return 0
	}
	if [ "$(printf '%s' "$asked" | jq -r 'type')" != array ]; then
		echo "cageworks: $field must be a list of endpoints" >&2
		return 1
	fi

	allowed="$(printf '%s' "$caps_file_json" | jq -c --arg f "$field" '.[$f] // []')"
	if [ "$(printf '%s' "$allowed" | jq -r 'type')" != array ]; then
		echo "cageworks: the ceiling for $field is not a list of endpoints" >&2
		return 1
	fi
	kept="$(jq -cn --argjson a "$asked" --argjson c "$allowed" '$a - ($a - $c)')"
	dropped="$(jq -rn --argjson a "$asked" --argjson c "$allowed" '($a - $c) | join(", ")')"
	if [ -n "$dropped" ]; then
		echo "cageworks: $field asked for $dropped, which this host does not allow; dropped" >&2
	fi

	printf '%s' "$declaration" |
		jq -c --arg f "$field" --argjson v "$kept" '.resources[$f] = $v'
}
