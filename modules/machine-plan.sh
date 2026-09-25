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

## Whether a cage of this name is running, asked of nixcage, which answers
## for the cage's scope (nixcage ADR-012). A hand entering a running role
## is put inside its cage rather than beside it.
fabriek_cage_running() {
	local name="$1"
	fabriek_name_ok "$name" || return 1
	case "$(fabriek_nixcage status "$name" 2>/dev/null)" in
	running\ *) return 0 ;;
	*) return 1 ;;
	esac
}

## What a session's --substrate is (ADR-067 point 4, nixcage ADR-019): the
## role's, or the lowest when it declared none; the clamp has raised it to
## the operator's floor already. The decider is not in the declaration and
## runs on the lowest.
fabriek_cage_substrate() {
	local declaration="$1" role="$2" s
	s="$(jq -r --arg r "$role" '.roles[$r].substrate // empty' "$declaration" 2>/dev/null)"
	printf '%s\n' "${s:-nspawn}"
}

## What a session's --network is: the bridge placement (nixcage ADR-011).
fabriek_cage_network() {
	local plan="$1" role="$2" address
	address="$(fabriek_bridge_address "$plan" "$role")" || return 1
	fabriek_bridge_placement "$plan" "$address"
}

## The bounds a cage gets on its scope (nixcage ADR-012), one argv word per
## line: what the factory declared it may use, divided by how many tasks
## may be in flight at once, the same number the executor holds assignments
## to (ADR-055); with none declared, by the roles, since every role's
## session runs from up. Never less than one cpu. Nothing declared, nothing
## bounded: the machine's own size is the ceiling then.
fabriek_cage_bounds() {
	local declaration="$1" memory cores concurrency mib
	memory="$(jq -r '.resources.memory // empty' "$declaration")"
	cores="$(jq -r '.resources.cores // empty' "$declaration")"
	concurrency="$(jq -r '.resources.concurrency // (.roles | length)' "$declaration")"
	[ "$concurrency" -ge 1 ] 2>/dev/null || concurrency=1
	if [ -n "$memory" ]; then
		mib="$(fabriek_size_mib "$memory")" || return 1
		printf -- '--memory\n%sM\n' "$((mib / concurrency))"
	fi
	if [ -n "$cores" ]; then
		local cpus=$((cores / concurrency))
		[ "$cpus" -ge 1 ] || cpus=1
		printf -- '--cpus\n%s\n' "$cpus"
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

## A role's pi directory, rendered by prepare beside its profile
## (factory-render.sh), resolved like the profile.
fabriek_role_pi_dir() {
	local etc="$1" role="$2" link
	fabriek_name_ok "$role" || return 1
	link="$etc/roles/$role/pi"
	[ -L "$link" ] || [ -d "$link" ] || return 1
	readlink -f "$link"
}

## What a supervised session runs when the repository declares no command:
## the agent (ADR-029) in the mode the loop drives, on the model the build
## chose, trusting nothing the project's own .pi says. On argv rather than
## in settings.json: pi locks that file to read it, and the directory it is
## in is bound read-only, so a session with nobody at the keyboard started
## on no model. One word per line, like a declared command.
##
## fabriek_actor_command <etc>
fabriek_actor_command() {
	local etc="$1" provider model
	if [ ! -s "$etc/model.json" ]; then
		echo "fabriek: this machine's build wrote no model at $etc/model.json; a session cannot start on none" >&2
		return 1
	fi
	provider="$(jq -r '.provider // empty' "$etc/model.json")"
	model="$(jq -r '.model // empty' "$etc/model.json")"
	if [ -z "$provider" ] || [ -z "$model" ]; then
		echo "fabriek: $etc/model.json names no provider and model" >&2
		return 1
	fi
	printf '%s\n' pi --mode rpc --provider "$provider" --model "$model" --no-approve
}

## Where a session's pi scratch lives on the machine. FABRIEK_RUN overrides
## it, which is what the suite uses.
fabriek_run_dir() { printf '%s\n' "${FABRIEK_RUN:-/run/fabriek}"; }

## The directory pi is handed, made fresh for one supervised session and
## given to the role. pi locks settings.json, auth.json and models-store.json
## to read them, and the lock is a directory beside each, so what it is
## handed has to be writable; what the build put there is bound read-only
## over it by fabriek_actor_args, so the loop, the models and the prompt stay
## the build's and only pi's own state lands here. Fresh every session:
## nothing a role writes outlives the session that wrote it.
##
## fabriek_actor_scratch <role> <uid>
fabriek_actor_scratch() {
	local role="$1" uid="$2" dir
	dir="$(fabriek_run_dir)/pi-$role"
	rm -rf "$dir" && mkdir -p "$dir" && chmod 0700 "$dir" || return 1
	## The suite runs as a person and cannot give a directory away; on the
	## machine this runs as root and a directory it cannot give is a fault.
	chown "$uid" "$dir" 2>/dev/null || [ "$(id -u)" != 0 ] || return 1
	printf '%s\n' "$dir"
}

## What makes a supervised session an actor (ADR-033, ADR-035): pi's
## directory, scratch for the session with the build's files bound
## read-only over it, where PI_CODING_AGENT_DIR names it; the bus password
## and the forge token bound read-only; and the environment the extension
## reads. One flag per line, in a fixed order, because seam.bats asserts
## the whole line.
##
## fabriek_actor_args <etc> <state> <factory> <role> <scratch>
fabriek_actor_args() {
	local etc="$1" state="$2" factory="$3" role="$4" scratch="$5"
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
	## and reads the declaration and the policy rather than a capability. A
	## role runs the loop from its own directory, one store path the build
	## made beside its profile, carrying who it is (ADR-042 point 5); a
	## session without it would be an agent with no loop, so it is refused.
	local pidir capabilities="" specialists=""
	if [ "$role" = "$FABRIEK_DECIDER" ]; then
		## Resolved like a role's: one store path the build made, handed to
		## the session as a root the same way (nixcage ADR-014).
		pidir="$(readlink -f "$etc/pi-decider")"
	else
		if ! pidir="$(fabriek_role_pi_dir "$etc" "$role")"; then
			echo "fabriek: role $role has no pi directory at $etc/roles/$role/pi; the machine's build makes one per role" >&2
			return 1
		fi
		capabilities="$(jq -r --arg r "$role" '.roles[$r].provides | join(",")' "$etc/declaration.json")"
		specialists="$(jq -r --arg r "$role" '(.roles[$r].specialists // []) | join(",")' "$etc/declaration.json")"
	fi
	local forge bus proxy
	forge="$(jq -r .forgejo "$etc/bridge.json")"
	bus="$(jq -r .bus "$etc/bridge.json")"
	proxy="$(jq -r .proxy "$etc/bridge.json")"
	## The configuration directory is ours and read-only, named twice
	## because pi-lsp reads its servers from PI_AGENT_DIR (ADR-043); pi's sessions,
	## the verbatim transcript, go to the role's own home (ADR-038 point 2).
	## No startup network calls: a cage has no route, and a call that fails
	## slowly is a slow start nobody attributed (ADR-029 point 7).
	printf '%s\n' "--bind" "$scratch:/run/fabriek/pi"
	local entry
	for entry in "$pidir"/* "$pidir"/.[!.]*; do
		[ -e "$entry" ] || continue
		printf '%s\n' "--bind-ro" "$entry:/run/fabriek/pi/${entry##*/}"
	done
	## The directory's index files import the loop and the extensions from
	## the floor the image carries (floor.nix), so the cage has to see the
	## floor's closure: the floor is a root (nixcage ADR-014), and a bind
	## alone would show files that import nothing the cage can find.
	if [ -z "${FABRIEK_FLOOR:-}" ]; then
		echo "fabriek: FABRIEK_FLOOR is not set; the machine's image names the floor" >&2
		return 1
	fi
	printf '%s\n' "--store-root" "$FABRIEK_FLOOR"
	## The sessions go under the role's home, wherever the substrate binds
	## it (/root on nspawn, /home/nixcage on microvm: nixcage ADR-019); pi
	## expands ~ from HOME, which nixcage sets to that path. A fixed /root
	## was EACCES on microvm (2026-09-22).
	printf '%s\n' \
		"--setenv" "PI_CODING_AGENT_DIR=/run/fabriek/pi" \
		"--setenv" "PI_AGENT_DIR=/run/fabriek/pi" \
		"--setenv" "PI_CODING_AGENT_SESSION_DIR=~/.pi/sessions" \
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
		"--setenv" "FABRIEK_SPECIALISTS=$specialists" \
		"--setenv" "FABRIEK_BUS=$bus" \
		"--setenv" "FABRIEK_FORGE=http://$forge/api/v1" \
		"--setenv" "FABRIEK_REPOSITORY=$factory-operator/$factory" \
		"--setenv" "FABRIEK_BASE_BRANCH=main" \
		"--setenv" "FABRIEK_PROXY=$proxy" \
		"--setenv" "FABRIEK_HOME_HOST=$state/homes/$factory-$role"
}
