# shellcheck shell=bash
## What the kernel says a role ran, onto the bus (ADR-038 point 3).
##
## bpftrace prints one line per exec, exit or connect with the cgroup the
## kernel saw; each becomes one entry on the probes stream carrying that
## cgroup, the role whose cage it is and the line. A cage is its scope's
## cgroup (nixcage ADR-012), which nixcage names from the cage's scope and
## nothing off the machine can; a process that changed uid inside a cage is
## still that cage's, which a uid table could not say. Written as the probes
## user, which may write this stream and nothing else, so the third source
## stays independent of every role.
##
## Sourced by store path into fabriek-container beside names.sh and bus.sh.

## The table's age before a cgroup nobody owns makes it be asked again, in
## seconds: a cage's scope exists only while it runs, and a line from a
## service that is no role should not cost a call per line.
FABRIEK_PROBES_REFRESH=60

## Where the kernel's cgroup tree is; a variable so the suite points it at
## a fixture.
FABRIEK_CGROUP_ROOT="${FABRIEK_CGROUP_ROOT:-/sys/fs/cgroup}"

## A cgroup's id is its directory's inode.
## The scope's id and its children's: nspawn runs the payload in a child
## cgroup of the scope, and the id the kernel stamps on a process is the
## child's. One per line.
fabriek_probes_cgroup_id() {
	local dir="$FABRIEK_CGROUP_ROOT/$1" child
	stat -c %i "$dir" 2>/dev/null || return 1
	for child in "$dir"/*/; do
		[ -d "$child" ] && stat -c %i "$child" 2>/dev/null
	done
	return 0
}

## fabriek_probes_publish <state> <plan.json> <declaration.json>
## Reads bpftrace's lines on stdin until it closes. Before the probes user
## has a password the lines go to stdout, which is the unit's journal.
fabriek_probes_publish() {
	local state="$1" plan="$2" declaration="$3"
	local password host port
	password="$(fabriek_bus_dir "$state")/probes"
	host="$(jq -r '.valkey | split(":")[0]' "$plan")"
	port="$(jq -r '.valkey | split(":")[1]' "$plan")"
	local -a roles=()
	local r
	while IFS= read -r r; do roles+=("$r"); done < <(jq -r '.roles | keys[]' "$declaration")
	roles+=("$FABRIEK_DECIDER")

	local -A role_of=()
	local asked=0
	local line cgroup role now
	while IFS= read -r line; do
		cgroup="${line#* cgroup=}"
		cgroup="${cgroup%% *}"
		now="$(date +%s)"
		if [ -z "${role_of[$cgroup]+x}" ] && [ $((now - asked)) -ge "$FABRIEK_PROBES_REFRESH" ]; then
			role_of=()
			for r in "${roles[@]}"; do
				local status path id
				status="$(nixcage-container status "$r" 2>/dev/null)" || continue
				case "$status" in
				running\ *)
					read -r _ _ path <<<"$status"
					while IFS= read -r id; do
						[ -n "$id" ] && role_of[$id]="$r"
					done < <(fabriek_probes_cgroup_id "$path")
					;;
				esac
			done
			asked="$now"
		fi
		role="${role_of[$cgroup]:-}"
		if [ -s "$password" ]; then
			## The password reaches valkey-cli through its environment rather
			## than its arguments, which /proc shows to every uid on the machine.
			VALKEYCLI_AUTH="$(cat "$password")" valkey-cli -h "$host" -p "$port" \
				--user probes --no-auth-warning \
				XADD probes MAXLEN '~' "$FABRIEK_PROBES_CAP" '*' cgroup "$cgroup" role "$role" event "$line" >/dev/null
		else
			printf '%s\n' "$line"
		fi
	done
}

## How many entries the stream keeps (roadmap 2.2): the operator watches it
## live and nothing persists it.
FABRIEK_PROBES_CAP=10000
