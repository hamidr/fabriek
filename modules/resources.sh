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
fabriek_resource_fields() {
	printf '%s\t%s\n' \
		memory size \
		cores count \
		roleQuota size \
		tokens count \
		concurrency count \
		taskAttempts count \
		runTimeoutSeconds count \
		egress set
}

## What the operator may cap beyond the resources table: the substrate floor
## (ADR-067 point 4), which is a role's field and not a resource, so the
## declaration's schema does not read it from here.
fabriek_cap_field_names_json() {
	fabriek_resource_field_names_json | jq -c '. + ["substrate"]'
}

## The substrates a role may run on (nixcage ADR-019), lowest first: the
## operator's floor raises a role to its own and lowers none.
fabriek_substrates() {
	printf '%s\n' nspawn microvm
}

## A substrate's rank in that order, or a refusal naming where it came from.
fabriek_substrate_rank() {
	local value="$1" where="$2" rank=0 s
	while IFS= read -r s; do
		[ "$s" = "$value" ] && { printf '%s\n' "$rank"; return 0; }
		rank=$((rank + 1))
	done < <(fabriek_substrates)
	echo "fabriek: $where is not a substrate: $value" >&2
	return 1
}

## The floor met against every role (ADR-067 point 4): a role asking for
## less than the operator's floor, or for nothing, is raised to it and
## told; one at or above it is left alone. Declaration on standard input,
## the same declaration out. This is the one field that lives on a role
## rather than under resources, since a substrate is a fact about one
## cage.
fabriek_resources_floor() {
	local field="$1" caps="$2" declaration floor floor_n role asked asked_n
	declaration="$(cat)"
	floor="$(printf '%s' "$caps" | jq -r --arg f "$field" '.[$f] // empty')"
	if [ -z "$floor" ]; then
		printf '%s\n' "$declaration"
		return 0
	fi
	floor_n="$(fabriek_substrate_rank "$floor" "the floor for $field")" || return 1
	while IFS= read -r role; do
		asked="$(printf '%s' "$declaration" | jq -r --arg r "$role" --arg f "$field" '.roles[$r][$f] // empty')"
		asked_n=0
		[ -z "$asked" ] || asked_n="$(fabriek_substrate_rank "$asked" "role $role's $field")" || return 1
		[ "$asked_n" -lt "$floor_n" ] || continue
		echo "fabriek: $field: role $role asked for ${asked:-$(fabriek_substrates | head -1)} and this host's floor is $floor; raised to $floor" >&2
		declaration="$(printf '%s' "$declaration" |
			jq --arg r "$role" --arg f "$field" --arg v "$floor" '.roles[$r][$f] = $v')"
	done < <(printf '%s' "$declaration" | jq -r '.roles // {} | keys[]')
	printf '%s\n' "$declaration"
}

## The same table as a JSON array, for the schemas that need to say which keys
## they allow.
fabriek_resource_field_names_json() {
	fabriek_resource_fields | cut -f1 | jq -Rrn '[inputs] | tojson'
}

## A declared value as a number that can be compared. A size becomes bytes; a
## count is already one. Anything else is a mistake in whichever declaration it
## came from, and is named rather than read as zero.
fabriek_resource_magnitude() {
	local kind="$1" value="$2" where="$3"
	case "$kind" in
	size)
		fabriek_size_bytes "$value" 2>/dev/null && return 0
		echo "fabriek: $where is not a size: $value" >&2
		return 1
		;;
	*)
		if [[ ! "$value" =~ ^[0-9]+$ ]]; then
			echo "fabriek: $where is not a count: $value" >&2
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
fabriek_resources_clamp() {
	local caps_file="$1" declaration caps field kind asked ceiling asked_n ceiling_n
	declaration="$(cat)"

	if [ ! -f "$caps_file" ]; then
		echo "fabriek: no ceilings to clamp against: $caps_file" >&2
		return 1
	fi
	caps="$(cat "$caps_file")"

	while IFS=$'\t' read -r field kind; do
		if [ "$kind" = set ]; then
			declaration="$(printf '%s' "$declaration" |
				fabriek_resources_intersect "$field" "$caps")" || return 1
			continue
		fi

		asked="$(printf '%s' "$declaration" | jq -r --arg f "$field" '.resources[$f] // empty')"
		[ -n "$asked" ] || continue
		ceiling="$(printf '%s' "$caps" | jq -r --arg f "$field" '.[$f] // empty')"

		asked_n="$(fabriek_resource_magnitude "$kind" "$asked" "$field")" || return 1
		[ -n "$ceiling" ] || continue
		ceiling_n="$(fabriek_resource_magnitude "$kind" "$ceiling" "the ceiling for $field")" || return 1

		[ "$asked_n" -gt "$ceiling_n" ] || continue
		echo "fabriek: $field asked for $asked and this host allows $ceiling; clamped to $ceiling" >&2
		declaration="$(printf '%s' "$declaration" |
			jq --arg f "$field" --argjson v "$(printf '%s' "$caps" | jq --arg f "$field" '.[$f]')" \
				'.resources[$f] = $v')"
	done < <(fabriek_resource_fields)

	declaration="$(printf '%s' "$declaration" | fabriek_resources_floor substrate "$caps")" || return 1
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
fabriek_resources_intersect() {
	local field="$1" caps_file_json="$2" declaration asked allowed kept dropped
	declaration="$(cat)"

	asked="$(printf '%s' "$declaration" | jq -c --arg f "$field" '.resources[$f] // empty')"
	[ -n "$asked" ] || {
		printf '%s\n' "$declaration"
		return 0
	}
	if [ "$(printf '%s' "$asked" | jq -r 'type')" != array ]; then
		echo "fabriek: $field must be a list of endpoints" >&2
		return 1
	fi

	allowed="$(printf '%s' "$caps_file_json" | jq -c --arg f "$field" '.[$f] // []')"
	if [ "$(printf '%s' "$allowed" | jq -r 'type')" != array ]; then
		echo "fabriek: the ceiling for $field is not a list of endpoints" >&2
		return 1
	fi
	kept="$(jq -cn --argjson a "$asked" --argjson c "$allowed" '$a - ($a - $c)')"
	dropped="$(jq -rn --argjson a "$asked" --argjson c "$allowed" '($a - $c) | join(", ")')"
	if [ -n "$dropped" ]; then
		echo "fabriek: $field asked for $dropped, which this host does not allow; dropped" >&2
	fi

	printf '%s' "$declaration" |
		jq -c --arg f "$field" --argjson v "$kept" '.resources[$f] = $v'
}
