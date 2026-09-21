#!/usr/bin/env bash
## ADR-067's measurement plan for two factories on one host, which needs
## the host's units and bridges for real and so cannot be a bats test: each
## factory in a slice of its own on a bridge of its own, a role of one
## reaching its own bus and not the other's, one down leaving the other
## running, and the memory a factory costs idle.
##
## Wants a NixOS host whose services.fabriek declares two factories, named
## by A and B (default acme and widgets), each with at least one role, and
## a scratch directory.
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   A=acme B=widgets tests/manual/two-factories.sh
set -uo pipefail
A="${A:-acme}"
B="${B:-widgets}"
F="$A"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"
FACTS_DIR="${FABRIEK_FACTORIES:-/etc/fabriek/factories}"
[ -f "$FACTS_DIR/$B.env" ] || {
	echo "the factory $B is not declared on this host: no $FACTS_DIR/$B.env"
	exit 1
}
fact_of() { sed -n "s/^$2=//p" "$FACTS_DIR/$1.env"; }
bridge_a="$(fact_of "$A" FABRIEK_BRIDGE)"
bridge_b="$(fact_of "$B" FABRIEK_BRIDGE)"
host_a="$(fact_of "$A" FABRIEK_BRIDGE_HOST)"
host_b="$(fact_of "$B" FABRIEK_BRIDGE_HOST)"
port="$(fact_of "$A" FABRIEK_VALKEY_PORT)"
both_down() {
	bash fabriek down "$A" >/dev/null 2>&1
	bash fabriek down "$B" >/dev/null 2>&1
}

scenario "Two factories come up, each in its slice on its bridge"
when "both are brought up"
bash fabriek up "$A" || exit 1
bash fabriek up "$B" || exit 1
check "$A's slice holds its units" yes "$(systemctl list-units --no-legend "fabriek-$A-*" | grep -q executor && echo yes || echo no)"
check "$B's slice holds its units" yes "$(systemctl list-units --no-legend "fabriek-$B-*" | grep -q executor && echo yes || echo no)"
check "the bridges differ" yes "$([ "$bridge_a" != "$bridge_b" ] && echo yes || echo no)"
check "$bridge_a is up at $host_a" yes "$(ip -4 -o addr show "$bridge_a" | grep -q "$host_a/" && echo yes || echo no)"
check "$bridge_b is up at $host_b" yes "$(ip -4 -o addr show "$bridge_b" | grep -q "$host_b/" && echo yes || echo no)"

scenario "A role of one factory reaches its own bus and not the other's"
role_a="$(jq -r '.declaration.roles | keys[0]' "$(spec_json)")"
wait_cages "$role_a" || {
	echo "the actor's cage for $A's $role_a never came up"
	both_down
	exit 1
}
given "$A's $role_a in its cage"
when "it opens a connection to its own bus at $host_a:$port"
check "the connection is made" connected \
	"$(in_cage "$role_a" bash -c "exec 3<>/dev/tcp/$host_a/$port" >/dev/null 2>&1 && echo connected || echo refused)"
when "it opens a connection to $B's bus at $host_b:$port"
check "the connection fails" refused \
	"$(in_cage "$role_a" bash -c "exec 3<>/dev/tcp/$host_b/$port" >/dev/null 2>&1 && echo connected || echo refused)"

scenario "What a factory costs idle"
given "$A up with no task filed"
echo "  memory of fabriek-$A.slice: $(systemctl show "fabriek-$A.slice" -p MemoryCurrent --value 2>/dev/null) bytes"

scenario "One factory down leaves the other running"
when "$A is brought down"
bash fabriek down "$A" >/dev/null 2>&1
check "$A's executor is inactive" inactive "$(systemctl is-active "fabriek-$A-executor" 2>/dev/null)"
check "$B's executor is still active" active "$(systemctl is-active "fabriek-$B-executor" 2>/dev/null)"
check "fabriek ps says so" "stopped,running" \
	"$(bash fabriek ps --json | jq -r --arg a "$A" --arg b "$B" '[(.[] | select(.factory == $a) | .state), (.[] | select(.factory == $b) | .state)] | join(",")')"

both_down
exit "$fail"
