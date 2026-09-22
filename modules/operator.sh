# shellcheck shell=bash
## The operator's way into the executor (ADR-039 point 1): one entry on the
## operator stream per intervention, written as the executor's own bus user,
## so that every intervention is recorded and the executor is the only thing
## that acts on it. A title or a body is a file on the machine, never a word
## the executor re-reads off argv.
##
## Sourced by store path into fabriek-container beside names.sh and bus.sh.

## fabriek_operator_send <factory> <state> <plan.json> <json>
fabriek_operator_send() {
	local factory="$1" state="$2" plan="$3" json="$4"
	local password url
	password="$(fabriek_bus_dir "$state")/executor"
	if [ ! -s "$password" ]; then
		echo "fabriek: the executor has no bus password at $password; run fabriek up" >&2
		return 1
	fi
	url="nats://$(jq -r .bus "$plan")"
	## An entry is the fields a reader takes, as the package writes them.
	## The password reaches natscli through its environment rather than its
	## arguments, which /proc shows to every uid on the host.
	NATS_URL="$url" NATS_USER="$factory-executor" NATS_PASSWORD="$(cat "$password")" \
		nats pub operator "$(jq -cn --arg json "$json" '{json: $json}')" >/dev/null
}

## Where a filed goal's title and body are kept for the executor to read: a
## directory of the operator's, one per filing, under the state directory.
fabriek_operator_filed() {
	local state="$1" dir
	dir="$state/filed/$(date +%s)-$$"
	mkdir -p "$dir"
	printf '%s\n' "$dir"
}
