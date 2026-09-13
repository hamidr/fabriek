# shellcheck shell=bash
## The bus's users, prepared and prepared again (ADR-033 point 3).
##
## A password per user under the state directory, made once and readable by
## root alone; the machine's ACL unit reads them at boot, and is restarted
## after they change so a new role's user appears without a reboot. The
## users are the declaration's roles plus the three the machine provides.
##
## Sourced by store path into fabriek-container beside names.sh.

fabriek_bus_dir() { printf '%s/bus\n' "$1"; }

## Every user the bus has, given the declaration file.
fabriek_bus_users() {
	local declaration="$1"
	jq -r '.roles | keys[]' "$declaration"
	printf '%s\n' decider executor probes
}

## A password, once.
fabriek_bus_ensure_password() {
	local state="$1" user="$2" file
	fabriek_name_ok "$user" || return 1
	file="$(fabriek_bus_dir "$state")/$user"
	[ -s "$file" ] && return 0
	mkdir -p "$(dirname "$file")"
	chmod 0700 "$(dirname "$file")"
	(umask 077 && fabriek_secret >"$file.new") && mv "$file.new" "$file"
	chmod 0400 "$file"
}

## The stream verbs an actor may speak, and nothing else.
FABRIEK_BUS_STREAM_VERBS="+xadd +xread +xrange +xrevrange +xlen +xinfo +ping"

## What one user may touch, as ACL rules (ADR-033 point 3). %R~ is read-only
## on a key pattern and %W~ write-only, which is the whole point: attribution
## on a findings stream is the ACL's rather than the message's. A role reads
## its mailbox and every findings stream, and writes its own control, findings
## and events streams; the decider reads everything and writes only commands;
## the probes write one stream; the executor holds the bus.
fabriek_bus_rules() {
	local user="$1"
	case "$user" in
	decider) printf '%s\n' "resetkeys resetchannels nocommands $FABRIEK_BUS_STREAM_VERBS %R~* %W~commands" ;;
	executor) printf '%s\n' "resetkeys resetchannels allcommands allkeys allchannels" ;;
	probes) printf '%s\n' "resetkeys resetchannels nocommands +xadd +ping %W~probes" ;;
	*) printf '%s\n' "resetkeys resetchannels nocommands $FABRIEK_BUS_STREAM_VERBS %R~mailbox:$user %W~control:$user %W~findings:$user %R~findings:* %W~events:$user" ;;
	esac
}

## Apply the ACL from the password files that exist, and turn the default
## user off last: turned off first it refuses this script's own SETUSERs as
## unauthenticated, which is what the first machine's executor found as
## WRONGPASS. On a second run the default is already off and the bus answers
## NOAUTH, so the script speaks as the executor, whose password reaches
## valkey-cli through its environment and not argv.
##
## fabriek_bus_apply <state> <plan.json> <declaration.json>
fabriek_bus_apply() {
	local state="$1" plan="$2" declaration="$3"
	local host port dir
	host="$(jq -r '.valkey | split(":")[0]' "$plan")"
	port="$(jq -r '.valkey | split(":")[1]' "$plan")"
	dir="$(fabriek_bus_dir "$state")"
	local -a as=()
	local _i
	for _i in $(seq 1 30); do
		valkey-cli -h "$host" -p "$port" ping 2>&1 | grep -q "PONG\|NOAUTH" && break
		sleep 1
	done
	if valkey-cli -h "$host" -p "$port" ping 2>&1 | grep -q NOAUTH; then
		if [ ! -s "$dir/executor" ]; then
			echo "fabriek: the bus's default user is off and there is no executor password at $dir/executor" >&2
			return 1
		fi
		export VALKEYCLI_AUTH
		VALKEYCLI_AUTH="$(cat "$dir/executor")"
		as=(--user executor --no-auth-warning)
	fi
	local user rules
	while IFS= read -r user; do
		[ -s "$dir/$user" ] || continue
		rules="$(fabriek_bus_rules "$user")"
		# shellcheck disable=SC2086  # the rules are ACL words, split on purpose
		valkey-cli -h "$host" -p "$port" ${as[@]+"${as[@]}"} \
			ACL SETUSER "$user" on ">$(cat "$dir/$user")" $rules | grep -q OK || return 1
	done < <(fabriek_bus_users "$declaration")
	valkey-cli -h "$host" -p "$port" ${as[@]+"${as[@]}"} ACL SETUSER default off | grep -q OK
}
