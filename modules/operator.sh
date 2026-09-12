# shellcheck shell=bash
## The operator's way into the executor (ADR-039 point 1): one entry on the
## operator stream per intervention, written as the executor's own bus user,
## so that every intervention is recorded and the executor is the only thing
## that acts on it. A title or a body is a file on the machine, never a word
## the executor re-reads off argv.
##
## Sourced by store path into cageworks-container beside names.sh and bus.sh.

## cageworks_operator_send <state> <plan.json> <json>
cageworks_operator_send() {
	local state="$1" plan="$2" json="$3"
	local password host port
	password="$(cageworks_bus_dir "$state")/executor"
	if [ ! -s "$password" ]; then
		echo "cageworks: the executor has no bus password at $password; run cageworks up" >&2
		return 1
	fi
	host="$(jq -r '.valkey | split(":")[0]' "$plan")"
	port="$(jq -r '.valkey | split(":")[1]' "$plan")"
	## The password reaches valkey-cli through its environment rather than
	## its arguments, which /proc shows to every uid on the machine.
	VALKEYCLI_AUTH="$(cat "$password")" valkey-cli -h "$host" -p "$port" \
		--user executor --no-auth-warning \
		XADD operator MAXLEN '~' 1000 '*' json "$json" >/dev/null
}

## Where a filed goal's title and body are kept for the executor to read: a
## directory of the operator's, one per filing, under the state directory.
cageworks_operator_filed() {
	local state="$1" dir
	dir="$state/filed/$(date +%s)-$$"
	mkdir -p "$dir"
	printf '%s\n' "$dir"
}
