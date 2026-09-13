# shellcheck shell=bash
## What a machine's build put on it for a session to read (ADR-037, ADR-040):
## the bridge plan that says where each cage is, and the profile each role's
## toolchain was realised into. Both come from the same declaration the rules
## and the labels were generated from, so a session that reads them cannot
## disagree with the machine it runs on.
##
## Sourced by store path into fabriek-container beside names.sh. A file
## rather than an inline string so shellcheck reads it and bats sources it.

## The address a role's cage has on the factory's bridge. A machine with no
## plan has no bridge, and a role the plan does not place would have no
## address, and both are refusals rather than a session off the bridge.
fabriek_bridge_address() {
	local plan="$1" role="$2" address
	fabriek_name_ok "$role" || return 1
	if [ ! -f "$plan" ]; then
		echo "fabriek: this machine has no bridge plan at $plan; no cage can be placed" >&2
		return 1
	fi
	address="$(jq -r --arg r "$role" '.cages[$r] // empty' "$plan")"
	if [ -z "$address" ]; then
		echo "fabriek: the bridge plan places no cage for role $role" >&2
		return 1
	fi
	printf '%s\n' "$address"
}

## The placement nixcage's --network takes: the bridge's name and the address
## with the bridge's prefix.
fabriek_bridge_placement() {
	local plan="$1" address="$2"
	jq -r --arg a "$address" '"\(.bridge):\($a)/\(.prefix)"' "$plan"
}

## The leader pid of a running cage of this name, or nothing. A cage is not
## registered with machined (nixcage enters with --register=no), so it is
## found through the nspawn that holds it: the one whose argv names the
## machine, and its child. Asked by a hand session before it takes a veth,
## because an actor's cage holds the role's one veth and one address.
fabriek_cage_leader() {
	local name="$1" nspawn
	fabriek_name_ok "$name" || return 1
	nspawn="$(pgrep -f -- "--machine=$name( |\$)" 2>/dev/null | head -1)"
	[ -n "$nspawn" ] || return 1
	pgrep -P "$nspawn" 2>/dev/null | head -1 | grep .
}

## What a session's --network is: a running cage's namespace when a hand
## joins one, the bridge placement otherwise (nixcage ADR-011).
fabriek_cage_network() {
	local plan="$1" role="$2" leader
	if leader="$(fabriek_cage_leader "$role")"; then
		printf 'ns:/proc/%s/ns/net\n' "$leader"
	else
		local address
		address="$(fabriek_bridge_address "$plan" "$role")" || return 1
		fabriek_bridge_placement "$plan" "$address"
	fi
}

## The store path of a role's profile, resolved through the machine's own
## symlink so that what the session is handed is a path the cage can read
## through its read-only store. Fails quietly when the build realised none.
fabriek_role_profile() {
	local etc="$1" role="$2" link
	fabriek_name_ok "$role" || return 1
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
## fabriek_actor_args <etc> <state> <factory> <role>
fabriek_actor_args() {
	local etc="$1" state="$2" factory="$3" role="$4"
	local password="$state/bus/$role" token="$state/forge/$role-token"
	if [ ! -s "$password" ]; then
		echo "fabriek: role $role has no bus password at $password; run fabriek up" >&2
		return 1
	fi
	if [ ! -s "$token" ]; then
		echo "fabriek: role $role has no forge token at $token; run fabriek up" >&2
		return 1
	fi
	## The decider runs the machine's own loop, in a directory of its own,
	## and reads the declaration and the policy rather than a capability.
	local pidir="$etc/pi" capabilities=""
	if [ "$role" = "$FABRIEK_DECIDER" ]; then
		pidir="$etc/pi-decider"
	else
		capabilities="$(jq -r --arg r "$role" '.roles[$r].provides | join(",")' "$etc/declaration.json")"
	fi
	local forge bus proxy
	forge="$(jq -r .forgejo "$etc/bridge.json")"
	bus="$(jq -r .valkey "$etc/bridge.json")"
	proxy="$(jq -r .proxy "$etc/bridge.json")"
	## The configuration directory is ours and read-only; pi's sessions,
	## the verbatim transcript, go to the role's own home (ADR-038 point 2).
	## No startup network calls: a cage has no route, and a call that fails
	## slowly is a slow start nobody attributed (ADR-029 point 7).
	printf '%s\n' \
		"--bind-ro" "$pidir:/run/fabriek/pi" \
		"--setenv" "PI_CODING_AGENT_DIR=/run/fabriek/pi" \
		"--setenv" "PI_CODING_AGENT_SESSION_DIR=/root/.pi/sessions" \
		"--setenv" "PI_OFFLINE=1" \
		"--bind-ro" "$password:/run/fabriek/bus-password" \
		"--bind-ro" "$token:/run/fabriek/forge-token" \
		"--setenv" "FABRIEK_BUS_PASSWORD=/run/fabriek/bus-password" \
		"--setenv" "FABRIEK_FORGE_TOKEN=/run/fabriek/forge-token"
	if [ "$role" = "$FABRIEK_DECIDER" ]; then
		printf '%s\n' \
			"--bind-ro" "$etc/declaration.json:/run/fabriek/declaration.json" \
			"--setenv" "FABRIEK_DECLARATION=/run/fabriek/declaration.json"
		if [ -s "$etc/decider-policy.md" ]; then
			printf '%s\n' \
				"--bind-ro" "$etc/decider-policy.md:/run/fabriek/policy.md" \
				"--setenv" "FABRIEK_POLICY=/run/fabriek/policy.md"
		fi
	fi
	printf '%s\n' \
		"--setenv" "FABRIEK_ROLE=$role" \
		"--setenv" "FABRIEK_CAPABILITIES=$capabilities" \
		"--setenv" "FABRIEK_BUS=$bus" \
		"--setenv" "FABRIEK_FORGE=http://$forge/api/v1" \
		"--setenv" "FABRIEK_REPOSITORY=operator/$factory" \
		"--setenv" "FABRIEK_BASE_BRANCH=main" \
		"--setenv" "FABRIEK_PROXY=$proxy" \
		"--setenv" "FABRIEK_HOME_HOST=$state/homes/$factory-$role"
}
