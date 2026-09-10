#!/usr/bin/env bash
## ADR-025's verification, which needs a real machine and so cannot be a bats
## test. A rule that is not loaded is not a rule.
##
## Boots a factory's machine and asks it two kinds of question, separately.
##
## Who may resolve a name, and who may open a connection. They were one
## question here until a machine turned up that could do neither, for reasons
## that had nothing to do with each other: /etc/resolv.conf pointed at a stub
## resolver that resolves under its own uid, and the filter dropped it. Every
## uid failed both, and a script that reported "denied" without saying which
## had failed called that a pass.
##
## So resolution is asked about on its own, and the connection checks are given
## an address rather than a name, so that a lookup cannot stand in for a rule.
## Every uid but two is denied both; the two are root, which has to substitute,
## and the proxy, which is the only way a factory reaches a host. The
## credential is on the machine and readable by one uid. And the proxy answers
## on loopback with the header the operator said, without the caller holding
## anything.
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
## Given an address and never a name. A name here would make a lookup part of
## the answer, and a machine that cannot resolve would then report every uid
## as denied and look like a machine whose rules work.
reaches() {
	local uid="$1" gid="$2" where="$3"
	sshm "setpriv --reuid $uid --regid $gid --clear-groups \
       timeout 10 bash -c 'exec 3<>/dev/tcp/$where' >/dev/null 2>&1 \
       && echo reached || echo denied"
}

## Whether a uid can turn the endpoint's name into an address. Asked with
## getent, so it is glibc's own resolution and the same path anything else on
## the machine takes.
resolves() {
	local uid="$1" gid="$2"
	sshm "setpriv --reuid $uid --regid $gid --clear-groups \
       timeout 10 getent hosts $host >/dev/null 2>&1 \
       && echo resolved || echo denied"
}

## The endpoint as an address, looked up once as root so the connection checks
## below are about the filter and nothing else. A machine that cannot get this
## far has a resolution fault, and the checks that follow would otherwise
## report it as a filter that works.
## getent ahosts, which is what a process about to connect gets: getaddrinfo
## drops a family the machine cannot route, where plain 'getent hosts' is a raw
## lookup that happily returns one. Neither is 'ahostsv4', which would pin the
## family and hide a machine answering with one it cannot reach -- the fault
## this line existed to expose in the first place.
addr="$(sshm "getent ahosts $host 2>/dev/null | awk '\$2 == \"STREAM\" {print \$1; exit}'")"
if [ -z "$addr" ]; then
	echo "FAIL root cannot resolve $host, so nothing below would mean what it says"
	bash cageworks down acme
	exit 1
fi
echo "ok   root resolves $host to $addr"

## 1a. The proxy resolves, because it is the thing that has to. nginx reaches
## an upstream by name, so a proxy that cannot look one up is a proxy that
## cannot proxy, whatever the packet rules say.
check "the proxy can resolve the endpoint it proxies" resolved \
	"$(sshm "setpriv --reuid \$(id -u cageworks-egress) --regid \$(id -g cageworks-egress) \
       --clear-groups timeout 10 getent hosts $host >/dev/null 2>&1 \
       && echo resolved || echo denied")"

## 1b. And an ordinary uid does not, which is the half that makes a denied uid
## denied rather than merely unrouted. A resolver that answers for everybody is
## a channel out of a machine that has none.
check "an ordinary uid cannot resolve a name" denied \
	"$(resolves 65534 65534)"

## 2. A uid that is neither root nor the proxy reaches nothing. Any uid will
## do: what is being checked is the default, and the default is what a role
## gets by nobody having written a rule for it.
check "an ordinary uid cannot leave the machine" denied \
	"$(reaches 65534 65534 "$addr/443")"

## 3. The proxy can, which is what makes it the way out rather than a second
## wall.
check "the proxy can leave the machine" reached \
	"$(sshm "setpriv --reuid \$(id -u cageworks-egress) --regid \$(id -g cageworks-egress) \
       --clear-groups timeout 10 bash -c 'exec 3<>/dev/tcp/$addr/443' >/dev/null 2>&1 \
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
