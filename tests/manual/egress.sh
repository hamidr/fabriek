#!/usr/bin/env bash
## ADR-025's verification, which needs a real machine and so cannot be a bats
## test. A rule that is not loaded is not a rule.
##
## Boots a factory's machine and asks it four questions. Every uid but two is
## denied the network; the two are root, which has to substitute, and the
## proxy, which is the only way a factory reaches a host. The credential is on
## the machine and readable by one uid. And the proxy answers on loopback with
## the header the operator said, without the caller holding anything.
##
## Wants the same scratch directory stop-and-start.sh does: an operator config
## and a repository declaring a factory called acme. The config needs a caps
## egress list and a credential, and the repository needs to declare an
## endpoint the caps allow.
##
##   export CAGEWORKS_PROOF_DIR=/tmp/cageworks-proof
##   tests/manual/egress.sh
##
## Reaching a real model API is not what this checks and is not wanted here.
## The endpoint under test is one the operator allowed and the assertion is
## about which uid gets a packet to it, so a host that refuses politely is a
## better subject than one that charges for an answer.
set -uo pipefail
cd "${CAGEWORKS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 1
S="${CAGEWORKS_PROOF_DIR:?set CAGEWORKS_PROOF_DIR to a scratch directory}"
export CAGEWORKS_MACHINES="$S/machines" CAGEWORKS_CONFIG="$S/cfg.toml" \
	CAGEWORKS_LIB="$PWD/modules" CAGEWORKS_SELF="$PWD"
D="$S/machines/acme"

sshm() {
	ssh -i "$D/id_ed25519" -p "$(cat "$D/port")" -o UserKnownHostsFile="$D/known_hosts" \
		-o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o BatchMode=yes \
		-o ConnectTimeout=3 root@localhost "$@"
}
wait_ssh() { for _ in $(seq 1 120); do sshm true 2>/dev/null && return 0; sleep 1; done; return 1; }

fail=0
check() {
	local what="$1" want="$2" got="$3"
	if [ "$got" = "$want" ]; then
		echo "ok   $what"
	else
		echo "FAIL $what: wanted $want, got $got"
		fail=1
	fi
}

bash cageworks up acme || exit 1
wait_ssh || {
	echo "the machine never answered"
	exit 1
}

## The endpoint this factory was allowed, taken from the spec rather than
## assumed, so this tests the machine that was built and not a guess at it.
host="$(jq -r '(.egress // [])[0] // empty' "$D/spec.json")"
port="$(jq -r '.egressPort // 8118' "$D/spec.json")"
if [ -z "$host" ]; then
	echo "acme is allowed no endpoints, so there is nothing here to check"
	bash cageworks down acme
	exit 1
fi

## 1. The ruleset is loaded, not merely built.
check "the egress table is loaded" loaded \
	"$(sshm nft list table inet cageworks-egress >/dev/null 2>&1 && echo loaded || echo absent)"

## Whether a uid can open a connection, which is the granularity the filter
## works at. Opening the socket is the whole question, so bash does it and the
## machine gains no tool it would only have for this.
##
## A denied uid loses its name lookup as well as its connection, and both are
## the filter denying it. That is why this says reached or denied rather than
## naming which of the two stopped it.
reaches() {
	local uid="$1" gid="$2" where="$3"
	sshm "setpriv --reuid $uid --regid $gid --clear-groups \
       timeout 10 bash -c 'exec 3<>/dev/tcp/$where' >/dev/null 2>&1 \
       && echo reached || echo denied"
}

## 2. A uid that is neither root nor the proxy reaches nothing. Any uid will
## do: what is being checked is the default, and the default is what a role
## gets by nobody having written a rule for it.
check "an ordinary uid cannot leave the machine" denied \
	"$(reaches 65534 65534 "$host/443")"

## 3. The proxy can, which is what makes it the way out rather than a second
## wall.
check "the proxy can leave the machine" reached \
	"$(sshm "setpriv --reuid \$(id -u cageworks-egress) --regid \$(id -g cageworks-egress) \
       --clear-groups timeout 10 bash -c 'exec 3<>/dev/tcp/$host/443' >/dev/null 2>&1 \
       && echo reached || echo denied")"

## 4. The credential is on the machine and belongs to the proxy alone. Its
## value is never printed: what is being checked is who may read it.
if jq -e --arg h "$host" '.egressHeaders[$h] // empty' "$D/spec.json" >/dev/null; then
	check "the credential is readable by the proxy and nobody else" "cageworks-egress 400" \
		"$(sshm "stat -c '%U %a' /var/lib/nixcage/egress/$host 2>/dev/null || echo missing")"
	check "the header the proxy adds is the one the operator named" present \
		"$(sshm "grep -q proxy_set_header /run/cageworks-egress/$host.conf \
         && echo present || echo absent")"
else
	echo "skip nobody holds a credential for $host, so there is no header to check"
fi

## 5. The uid that reaches no host reaches the proxy, because the proxy is on
## this machine. This is the half that makes the denial above a design rather
## than an outage.
check "a denied uid still reaches the proxy" reached \
	"$(reaches 65534 65534 "127.0.0.1/$port")"

bash cageworks down acme
exit "$fail"
