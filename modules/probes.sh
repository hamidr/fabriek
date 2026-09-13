# shellcheck shell=bash
## What the kernel says a role ran, onto the bus (ADR-038 point 3).
##
## bpftrace prints one line per exec, exit or connect with the uid the kernel
## saw; each becomes one entry on the probes stream carrying that uid, the
## role it belongs to and the line. The role is the machine's to name, since
## nixcage allocated the uid (ADR-041) and answers by name and nothing off
## the machine can. Written as the probes user, which may write this stream
## and nothing else, so the third source stays independent of every role.
##
## Sourced by store path into cageworks-container beside names.sh and bus.sh.

## The table's age before a uid nobody owns makes it be asked again, in
## seconds: a role's uid is allocated when the factory is prepared, which is
## after this unit starts, and a process of a service that is no role
## should not cost the primitive a call per line.
CAGEWORKS_PROBES_REFRESH=60

## cageworks_probes_publish <state> <plan.json> <declaration.json>
## Reads bpftrace's lines on stdin until it closes. Before the probes user
## has a password the lines go to stdout, which is the unit's journal.
cageworks_probes_publish() {
	local state="$1" plan="$2" declaration="$3"
	local password host port
	password="$(cageworks_bus_dir "$state")/probes"
	host="$(jq -r '.valkey | split(":")[0]' "$plan")"
	port="$(jq -r '.valkey | split(":")[1]' "$plan")"
	local -a roles=()
	local r
	while IFS= read -r r; do roles+=("$r"); done < <(jq -r '.roles | keys[]' "$declaration")
	roles+=("$CAGEWORKS_DECIDER")

	local -A role_of=()
	local asked=0
	local line uid role now
	while IFS= read -r line; do
		uid="${line#* uid=}"
		uid="${uid%% *}"
		now="$(date +%s)"
		if [ -z "${role_of[$uid]+x}" ] && [ $((now - asked)) -ge "$CAGEWORKS_PROBES_REFRESH" ]; then
			role_of=()
			for r in "${roles[@]}"; do
				local u
				u="$(nixcage-container uid "$r" 2>/dev/null)" && role_of[$u]="$r"
			done
			asked="$now"
		fi
		role="${role_of[$uid]:-}"
		if [ -s "$password" ]; then
			## The password reaches valkey-cli through its environment rather
			## than its arguments, which /proc shows to every uid on the machine.
			VALKEYCLI_AUTH="$(cat "$password")" valkey-cli -h "$host" -p "$port" \
				--user probes --no-auth-warning \
				XADD probes MAXLEN '~' "$CAGEWORKS_PROBES_CAP" '*' uid "$uid" role "$role" event "$line" >/dev/null
		else
			printf '%s\n' "$line"
		fi
	done
}

## How many entries the stream keeps (roadmap 2.2): the operator watches it
## live and nothing persists it.
CAGEWORKS_PROBES_CAP=10000
