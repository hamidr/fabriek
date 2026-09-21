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
## One reader serves every factory on the host (ADR-067): a cage is named
## <factory>-<role>, and the line goes to that factory's bus.
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

## The factories on this host, from the facts files the host module
## wrote: one line per factory, its name, its state directory and its
## rendered directory, tab-separated. A facts file names both; a factory
## with no declaration rendered yet has no cages and is skipped.
##
## fabriek_probes_factories <facts-dir>
fabriek_probes_factories() {
	local dir="$1" file name state etc
	for file in "$dir"/*.env; do
		[ -f "$file" ] || continue
		name="$(sed -n 's/^FABRIEK_FACTORY=//p' "$file")"
		state="$(sed -n 's/^FABRIEK_STATE=//p' "$file")"
		etc="$(sed -n 's/^FABRIEK_ETC=//p' "$file")"
		[ -n "$name" ] && [ -f "$etc/declaration.json" ] || continue
		printf '%s\t%s\t%s\n' "$name" "$state" "$etc"
	done
}

## fabriek_probes_publish <facts-dir>
## Reads bpftrace's lines on stdin until it closes. Each line goes to the
## bus of the factory whose cage the cgroup is; a line no cage owns, and a
## line for a factory whose probes user has no password yet, go to stdout,
## which is the unit's journal.
fabriek_probes_publish() {
	local facts="$1"
	local -A role_of=() factory_of=()
	local asked=0
	local line cgroup role factory now
	while IFS= read -r line; do
		cgroup="${line#* cgroup=}"
		cgroup="${cgroup%% *}"
		now="$(date +%s)"
		if [ -z "${role_of[$cgroup]+x}" ] && [ $((now - asked)) -ge "$FABRIEK_PROBES_REFRESH" ]; then
			role_of=()
			factory_of=()
			fabriek_probes_ask "$facts" role_of factory_of
			asked="$now"
		fi
		role="${role_of[$cgroup]:-}"
		factory="${factory_of[$cgroup]:-}"
		if [ -n "$factory" ] && [ -s "$(fabriek_probes_password "$facts" "$factory")" ]; then
			fabriek_probes_send "$facts" "$factory" "$cgroup" "$role" "$line"
		else
			printf '%s\n' "$line"
		fi
	done
}

## Every declared role's cage of every rendered factory, asked of nixcage
## for its scope, into the two tables named: cgroup id to role and to
## factory.
fabriek_probes_ask() {
	local facts="$1"
	local -n roles_out="$2" factories_out="$3"
	local name state etc r status path id
	while IFS=$'\t' read -r name state etc; do
		[ -n "$name" ] || continue
		while IFS= read -r r; do
			status="$(nixcage-container status "$name-$r" 2>/dev/null)" || continue
			case "$status" in
			running\ *)
				read -r _ _ path <<<"$status"
				while IFS= read -r id; do
					[ -n "$id" ] || continue
					# shellcheck disable=SC2034  # the caller's tables, by nameref
					roles_out["$id"]="$r"
					# shellcheck disable=SC2034
					factories_out["$id"]="$name"
				done < <(fabriek_probes_cgroup_id "$path")
				;;
			esac
		done < <(jq -r '.roles | keys[]' "$etc/declaration.json"; printf '%s\n' "$FABRIEK_DECIDER")
	done < <(fabriek_probes_factories "$facts")
}

fabriek_probes_password() {
	local facts="$1" factory="$2" state
	state="$(sed -n 's/^FABRIEK_STATE=//p' "$facts/$factory.env")"
	printf '%s\n' "$(fabriek_bus_dir "$state")/probes"
}

## One entry on the factory's probes stream, as its probes user. The
## password reaches valkey-cli through its environment rather than its
## arguments, which /proc shows to every uid on the host.
fabriek_probes_send() {
	local facts="$1" factory="$2" cgroup="$3" role="$4" line="$5" etc host port
	etc="$(sed -n 's/^FABRIEK_ETC=//p' "$facts/$factory.env")"
	host="$(jq -r '.valkey | split(":")[0]' "$etc/bridge.json")"
	port="$(jq -r '.valkey | split(":")[1]' "$etc/bridge.json")"
	VALKEYCLI_AUTH="$(cat "$(fabriek_probes_password "$facts" "$factory")")" valkey-cli -h "$host" -p "$port" \
		--user probes --no-auth-warning \
		XADD probes MAXLEN '~' "$FABRIEK_PROBES_CAP" '*' cgroup "$cgroup" role "$role" event "$line" >/dev/null
}

## How many entries the stream keeps (roadmap 2.2): the operator watches it
## live and nothing persists it.
FABRIEK_PROBES_CAP=10000
