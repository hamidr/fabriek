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

## What makes a supervised session an actor (ADR-033, ADR-035): pi's
## configuration directory bound where PI_CODING_AGENT_DIR names it, the bus
## password and the forge token bound read-only, and the environment the
## extension reads. One flag per line, in a fixed order, because seam.bats
## asserts the whole line.
##
## cageworks_actor_args <etc> <state> <factory> <role>
cageworks_actor_args() {
	local etc="$1" state="$2" factory="$3" role="$4"
	local password="$state/bus/$role" token="$state/forge/$role-token"
	if [ ! -s "$password" ]; then
		echo "cageworks: role $role has no bus password at $password; run cageworks up" >&2
		return 1
	fi
	if [ ! -s "$token" ]; then
		echo "cageworks: role $role has no forge token at $token; run cageworks up" >&2
		return 1
	fi
	## The decider runs the machine's own loop, in a directory of its own,
	## and reads the declaration and the policy rather than a capability.
	local pidir="$etc/pi" capabilities=""
	if [ "$role" = "$CAGEWORKS_DECIDER" ]; then
		pidir="$etc/pi-decider"
	else
		capabilities="$(jq -r --arg r "$role" '.roles[$r].provides | join(",")' "$etc/declaration.json")"
	fi
	local forge bus proxy
	forge="$(jq -r .forgejo "$etc/bridge.json")"
	bus="$(jq -r .valkey "$etc/bridge.json")"
	proxy="$(jq -r .proxy "$etc/bridge.json")"
	printf '%s\n' \
		"--bind-ro" "$pidir:/run/cageworks/pi" \
		"--setenv" "PI_CODING_AGENT_DIR=/run/cageworks/pi" \
		"--bind-ro" "$password:/run/cageworks/bus-password" \
		"--bind-ro" "$token:/run/cageworks/forge-token" \
		"--setenv" "CAGEWORKS_BUS_PASSWORD=/run/cageworks/bus-password" \
		"--setenv" "CAGEWORKS_FORGE_TOKEN=/run/cageworks/forge-token"
	if [ "$role" = "$CAGEWORKS_DECIDER" ]; then
		printf '%s\n' \
			"--bind-ro" "$etc/declaration.json:/run/cageworks/declaration.json" \
			"--setenv" "CAGEWORKS_DECLARATION=/run/cageworks/declaration.json"
		if [ -s "$etc/decider-policy.md" ]; then
			printf '%s\n' \
				"--bind-ro" "$etc/decider-policy.md:/run/cageworks/policy.md" \
				"--setenv" "CAGEWORKS_POLICY=/run/cageworks/policy.md"
		fi
	fi
	printf '%s\n' \
		"--setenv" "CAGEWORKS_ROLE=$role" \
		"--setenv" "CAGEWORKS_CAPABILITIES=$capabilities" \
		"--setenv" "CAGEWORKS_BUS=$bus" \
		"--setenv" "CAGEWORKS_FORGE=http://$forge/api/v1" \
		"--setenv" "CAGEWORKS_REPOSITORY=operator/$factory" \
		"--setenv" "CAGEWORKS_BASE_BRANCH=main" \
		"--setenv" "CAGEWORKS_PROXY=$proxy" \
		"--setenv" "CAGEWORKS_HOME_HOST=$state/homes/$factory-$role"
}
