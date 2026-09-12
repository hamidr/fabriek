#!/usr/bin/env bash
## ADR-037's measurement plan, which needs a real machine and so cannot be a
## bats test. Written before the bridge exists (docs/roadmap.md 0.6) so that
## phase 2.4 has something to make pass; today every scenario fails at its
## first Then, and the first line of output says the bridge is absent.
##
## Replaces tests/manual/egress.sh, whose uid filter ADR-037 deletes.
##
## Wants the scratch directory the other proofs use: an operator config and a
## repository declaring a factory called acme with at least two roles, an
## egress ceiling that allows one host, a credential for it, and a token
## ceiling small enough to reach in a handful of requests.
##
##   export CAGEWORKS_PROOF_DIR=/tmp/cageworks-proof
##   tests/manual/isolation.sh
##
## What the machine must offer for these to pass, and where each is decided:
## a bridge named cageworks-<factory> (2.2); one veth per cage carrying one
## address (1.1, 2.2); the proxy on the bridge answering /status with a JSON
## object of tokens spent per source address (2.2); nftables on the machine
## dropping a packet whose source is not the sender's address (2.2).
set -uo pipefail
F=acme
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"

bash cageworks up "$F" || exit 1
wait_ssh || {
	echo "the machine never answered"
	exit 1
}

roles="$(jq -r '.roles | keys[]' "$D/spec.json" 2>/dev/null)"
a="$(printf '%s\n' "$roles" | sed -n 1p)"
b="$(printf '%s\n' "$roles" | sed -n 2p)"
if [ -z "$a" ] || [ -z "$b" ]; then
	echo "acme declares fewer than two roles, so cage-to-cage cannot be asked"
	bash cageworks down "$F"
	exit 1
fi
bridge="cageworks-$F"

## The address a role's cage was given, read from inside the cage, which is
## the only place the answer is not a guess.
addr_of() { in_cage "$1" ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1; }
## Tokens the proxy has counted for one source address.
spent_by() { sshm curl -s "http://$proxy/status" | jq -r --arg a "$1" '.[$a] // 0'; }

scenario "A cage is on the factory's bridge and nowhere else"
given "a factory whose machine is up"
when "a role's cage is entered"
check "the bridge $bridge exists on the machine" present \
	"$(sshm ip link show "$bridge" >/dev/null 2>&1 && echo present || echo absent)"
check "role $a sees exactly one interface besides lo" 1 \
	"$(in_cage "$a" ip -o link show | grep -vc ': lo:')"
addr_a="$(addr_of "$a")"
addr_b="$(addr_of "$b")"
check "role $a holds one global address" yes "$([ -n "$addr_a" ] && echo yes || echo no)"
check "role $b holds a different address" yes "$([ -n "$addr_b" ] && [ "$addr_a" != "$addr_b" ] && echo yes || echo no)"
check "role $a cannot change its own address" refused \
	"$(in_cage "$a" ip addr add 10.255.255.1/32 dev host0 >/dev/null 2>&1 && echo allowed || echo refused)"

proxy="$(sshm jq -r .proxy /etc/cageworks/bridge.json 2>/dev/null)"
check "the machine says where the proxy is on the bridge" yes "$([ -n "$proxy" ] && echo yes || echo no)"

scenario "A cage has no route off the machine"
given "role $a inside its cage"
when "it opens a connection to an address outside the machine"
check "the connection fails" refused \
	"$(in_cage "$a" bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && echo connected || echo refused)"
when "it resolves a name"
check "resolution fails" refused \
	"$(in_cage "$a" getent hosts example.com >/dev/null 2>&1 && echo resolved || echo refused)"

scenario "A cage cannot reach a peer"
given "roles $a and $b each in their cage, $b at $addr_b"
when "$a opens a connection to $b's address"
check "the connection fails" refused \
	"$(in_cage "$a" bash -c "exec 3<>/dev/tcp/$addr_b/22" >/dev/null 2>&1 && echo connected || echo refused)"
when "$a opens a connection to the proxy"
check "the proxy answers" answered \
	"$(in_cage "$a" curl -s -o /dev/null -w '%{http_code}' "http://$proxy/status" 2>/dev/null | grep -q '^[0-9]' && echo answered || echo silent)"

scenario "Spend is attributed to the sender and to nobody else"
given "the proxy's count for $addr_a and $addr_b"
before_a="$(spent_by "$addr_a")"
before_b="$(spent_by "$addr_b")"
when "$a sends one request through the proxy"
in_cage "$a" curl -s -o /dev/null -X POST -H 'content-type: application/json' \
	-d '{"model":"probe","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
	"http://$proxy/v1/messages" >/dev/null 2>&1
check "$a's count moved" moved "$([ "$(spent_by "$addr_a")" != "$before_a" ] && echo moved || echo still)"
check "$b's count did not" still "$([ "$(spent_by "$addr_b")" = "$before_b" ] && echo still || echo moved)"

scenario "A forged source address is dropped at the bridge"
given "root on the machine inside $a's network namespace"
pid="$(sshm "machinectl show --property=Leader --value $F-$a 2>/dev/null")"
check "the cage's leader pid is known" yes "$([ -n "$pid" ] && echo yes || echo no)"
before_b="$(spent_by "$addr_b")"
when "a request leaves $a's veth carrying $b's address"
sshm "nsenter -t '$pid' -n sh -c 'ip addr add $addr_b/32 dev host0 2>/dev/null; curl -s -m 3 --interface $addr_b -o /dev/null -X POST http://$proxy/v1/messages; ip addr del $addr_b/32 dev host0 2>/dev/null'" >/dev/null 2>&1
check "$b's count did not move" still "$([ "$(spent_by "$addr_b")" = "$before_b" ] && echo still || echo moved)"

scenario "The hard limit is the proxy's"
ceiling="$(jq -r '.tokenCeiling // empty' "$D/spec.json")"
given "a token ceiling of ${ceiling:-none} in the spec"
check "a ceiling is declared" yes "$([ -n "$ceiling" ] && echo yes || echo no)"
when "$a sends requests until the proxy refuses"
code=""
for _ in $(seq 1 50); do
	code="$(in_cage "$a" curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
		-d '{"model":"probe","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
		"http://$proxy/v1/messages" 2>/dev/null)"
	[ "$code" = 429 ] && break
done
check "the proxy answers 429 at the hard limit" 429 "$code"

bash cageworks down "$F"
exit "$fail"
