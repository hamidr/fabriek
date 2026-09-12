# shellcheck shell=bash
## What a machine's build put on it for a session to read (ADR-037, ADR-040):
## the bridge plan that says where each cage is, and the profile each role's
## toolchain was realised into. Both come from the same declaration the rules
## and the labels were generated from, so a session that reads them cannot
## disagree with the machine it runs on.
##
## Sourced by store path into cageworks-container beside names.sh. A file
## rather than an inline string so shellcheck reads it and bats sources it.

## The address a role's cage has on the factory's bridge. A machine with no
## plan has no bridge, and a role the plan does not place would have no
## address, and both are refusals rather than a session off the bridge.
cageworks_bridge_address() {
	local plan="$1" role="$2" address
	cageworks_name_ok "$role" || return 1
	if [ ! -f "$plan" ]; then
		echo "cageworks: this machine has no bridge plan at $plan; no cage can be placed" >&2
		return 1
	fi
	address="$(jq -r --arg r "$role" '.cages[$r] // empty' "$plan")"
	if [ -z "$address" ]; then
		echo "cageworks: the bridge plan places no cage for role $role" >&2
		return 1
	fi
	printf '%s\n' "$address"
}

## The placement nixcage's --network takes: the bridge's name and the address
## with the bridge's prefix.
cageworks_bridge_placement() {
	local plan="$1" address="$2"
	jq -r --arg a "$address" '"\(.bridge):\($a)/\(.prefix)"' "$plan"
}

## The store path of a role's profile, resolved through the machine's own
## symlink so that what the session is handed is a path the cage can read
## through its read-only store. Fails quietly when the build realised none.
cageworks_role_profile() {
	local etc="$1" role="$2" link
	cageworks_name_ok "$role" || return 1
	link="$etc/roles/$role/profile"
	[ -L "$link" ] || [ -d "$link" ] || return 1
	readlink -f "$link"
}
