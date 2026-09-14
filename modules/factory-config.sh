# shellcheck shell=bash
## The roles a factory declares, read out of the declaration its repository
## carries (ADR-020).
##
## These used to read a directory tree the platform module rendered. They read
## one JSON value now, and take it as a file rather than as text so that
## nothing a repository wrote ever becomes an argument. What changed is where
## the answers come from; what each of these answers did not change, which is
## why the machine program's call sites look the same as they did.
##
## Sourced by store path into fabriek-container beside names.sh, whose
## fabriek_name_ok and fabriek_shell_name_ok this file relies on.

## The roles a factory declares, one per line, in a stable order. Alphabetical
## rather than as written, because nix sorts an attribute set's names and the
## order somebody typed them in does not survive evaluation.
##
## A factory with no roles is a declaration mistake rather than an empty
## factory, so it is refused here instead of producing a factory nothing can
## run in.
fabriek_factory_roles() {
	local declaration="$1" roles
	roles="$(jq -r '(.roles // {}) | keys[]?' "$declaration")" || return 1
	if [ -z "$roles" ]; then
		echo "fabriek: this declaration declares no roles" >&2
		return 1
	fi
	printf '%s\n' "$roles"
}

## Whether a role is one this factory declares, with the ones it does declare
## named when it is not. Every reader below goes through this, so asking about
## a role that does not exist says the same thing wherever it is asked.
fabriek_factory_role_declared() {
	local declaration="$1" role="$2"
	fabriek_name_ok "$role" || {
		echo "fabriek: invalid role name: $role" >&2
		return 1
	}
	if [ "$(jq -r --arg r "$role" '(.roles // {}) | has($r)' "$declaration")" = "true" ]; then
		return 0
	fi
	{
		echo "fabriek: this factory declares no role $role; it has:"
		fabriek_factory_roles "$declaration" | sed 's/^/  /'
	} >&2
	return 1
}

## What a role's session runs, one argv word per line, or nothing: a command
## is argv and never a shell line, so nothing in it is re-split or expanded
## on the way. A role that declares none prints none, and runs the agent
## (ADR-029) the way the machine composes it (fabriek_actor_command).
fabriek_factory_role_command() {
	local declaration="$1" role="$2"
	fabriek_factory_role_declared "$declaration" "$role" || return 1
	jq -r --arg r "$role" '(.roles[$r].command // []) | .[]' "$declaration"
}

## The specialists a role is composed of, one name per line, or nothing when
## it names none. A name becomes a directory under a catalogue, so it is
## checked here as well as in the schema: this is the last place before it
## reaches a path.
fabriek_factory_role_specialists() {
	local declaration="$1" role="$2" name
	fabriek_factory_role_declared "$declaration" "$role" || return 1
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if ! fabriek_name_ok "$name"; then
			echo "fabriek: role $role names an unusable specialist: $name" >&2
			return 1
		fi
		printf '%s\n' "$name"
	done < <(jq -r --arg r "$role" '(.roles[$r].specialists // []) | .[]' "$declaration")
}

## The devShell a role works in, or nothing when it names none. A specialist is
## a role with its own toolchain, and the toolchain is one devShell of the
## project's own flake: the repository declares what a JVM specialist or a
## frontend specialist has to hand, and fabriek only carries the name across
## (ADR-016).
##
## Checked here as well as in the declaration's own schema, because this is the
## last place before the name reaches a flake reference.
fabriek_factory_role_shell() {
	local declaration="$1" role="$2" want
	fabriek_factory_role_declared "$declaration" "$role" || return 1
	want="$(jq -r --arg r "$role" '.roles[$r].shell // empty' "$declaration")" || return 1
	[ -n "$want" ] || return 0
	if ! fabriek_shell_name_ok "$want"; then
		echo "fabriek: role $role declares an unusable devShell name: $want" >&2
		return 1
	fi
	printf '%s\n' "$want"
}

## What a role can do, one capability per line. A role that declares none can
## take no stage's work: capability is what a stage resolves through, so an
## undeclared one is a role with a cage and nothing to do (ADR-015).
fabriek_factory_role_provides() {
	local declaration="$1" role="$2"
	fabriek_factory_role_declared "$declaration" "$role" || return 1
	jq -r --arg r "$role" '(.roles[$r].provides // []) | .[]' "$declaration"
}

## The roles that provide a capability, in the same stable order. Which of them
## ends up working a task is ADR-023's business; what this answers is which of
## them could.
fabriek_factory_roles_providing() {
	local declaration="$1" capability="$2"
	[ -n "$capability" ] || return 1
	jq -r --arg c "$capability" '
    (.roles // {}) | to_entries
    | map(select((.value.provides // []) | index($c)))
    | sort_by(.key) | .[].key' "$declaration"
}
