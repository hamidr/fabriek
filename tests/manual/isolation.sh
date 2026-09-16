#!/usr/bin/env bash
## ADR-037's measurement plan, which needs a real machine and so cannot be a
## bats test. Written before the bridge exists (docs/roadmap.md 0.6) so that
## phase 2.4 has something to make pass; today every scenario fails at its
## first Then, and the first line of output says the bridge is absent.
##
## Replaced tests/manual/egress.sh, whose uid filter ADR-037 deleted; that
## script, with moves-in.sh and observe.sh, is in the history for the ADRs
## that cite them.
##
## Wants the scratch directory the other proofs use: an operator config and a
## repository declaring a factory called acme with at least two roles, an
## egress ceiling that allows one host, a credential for it, and a token
## ceiling small enough to reach in a handful of requests.
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   tests/manual/isolation.sh
##
## What the machine must offer for these to pass, and where each is decided:
## a bridge named fabriek-<factory> (2.2); one veth per cage carrying one
## address (1.1, 2.2); the proxy on the bridge answering /status with a JSON
## object of tokens spent per source address (2.2); nftables on the machine
## dropping a packet whose source is not the sender's address (2.2).
set -uo pipefail
F="${F:-acme}"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"

bash fabriek up "$F" || exit 1
wait_ssh || {
	echo "the machine never answered"
	exit 1
}

roles="$(jq -r '.declaration.roles | keys[]' "$(spec_json)" 2>/dev/null)"
a="$(printf '%s\n' "$roles" | sed -n 1p)"
b="$(printf '%s\n' "$roles" | sed -n 2p)"
if [ -z "$a" ] || [ -z "$b" ]; then
	echo "acme declares fewer than two roles, so cage-to-cage cannot be asked"
	bash fabriek down "$F"
	exit 1
fi
bridge="fabriek-$F"

## The executor keeps one session per role, and a cage is one veth and one
## address on the bridge under the role's name. A hand session joins the
## running cage's network (nixcage ADR-011 point 5), so this proof asks its
## questions beside the actors rather than in their place.

## The address a role's cage was given, read from inside the cage, which is
## the only place the answer is not a guess.
## Asked as JSON, because ip colours a terminal and a cage's stdio is one;
## filtered to an address, so that a cage without ip answers nothing rather
## than the first word of an error.
addr_of() { in_cage "$1" ip -j -4 addr show scope global | tr -d '\r' | jq -r '.[].addr_info[] | select(.scope == "global") | .local' 2>/dev/null | grep -oE '^[0-9.]+$' | head -1; }
## The interfaces a cage has, from the kernel and not from a tool. Read from
## /proc/net/dev, which is the namespace's own; /sys/class/net in a session
## that joined a namespace by path is the host's sysfs and lists the host's.
interfaces_of() { in_cage "$1" cat /proc/net/dev | tr -d '\r' | tail -n +3 | cut -d: -f1 | tr -d ' ' | grep -v '^lo$' | paste -sd, -; }
## Tokens the proxy has counted for one source address.
spent_by() { sshm curl -s "http://$proxy/status" | jq -r --arg a "$1" '.[$a] // 0'; }

scenario "A cage is on the factory's bridge and nowhere else"
given "a factory whose machine is up and its actors running"
check "the executor is running the actors" active "$(sshm systemctl is-active fabriek-executor 2>/dev/null)"
when "a role's cage is entered by hand, beside its actor"
check "the bridge $bridge exists on the machine" present \
	"$(sshm ip link show "$bridge" >/dev/null 2>&1 && echo present || echo absent)"
check "role $a sees host0 and nothing else besides lo" host0 "$(interfaces_of "$a")"
addr_a="$(addr_of "$a")"
addr_b="$(addr_of "$b")"
check "role $a holds one global address" yes "$([ -n "$addr_a" ] && echo yes || echo no)"
check "role $b holds a different address" yes "$([ -n "$addr_b" ] && [ "$addr_a" != "$addr_b" ] && echo yes || echo no)"

proxy="$(sshm cat /etc/fabriek/bridge.json 2>/dev/null | jq -r .proxy)"
check "the machine says where the proxy is on the bridge" yes "$([ -n "$proxy" ] && echo yes || echo no)"
## The proxy's location for a model endpoint is the endpoint's name (ADR-037
## point 3); a request to the provider lands there and leaves with the
## credential the operator holds.
endpoint="$(jq -r '.egress[0] // empty' "$(spec_json)")"
check "the spec allows one endpoint the proxy can be asked for" yes "$([ -n "$endpoint" ] && echo yes || echo no)"
messages="http://$proxy/$endpoint/v1/messages"

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

## One request to the endpoint, answering the status the endpoint gave.
## Spend is counted from the endpoint's answer, so an endpoint that refuses
## the credential (401) leaves nothing to count, and the two Thens that need
## a count are gated on it rather than failed.
ask_model() {
	in_cage "$1" curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
		-d '{"model":"probe","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
		"$messages" 2>/dev/null | tr -d '\r'
}

scenario "Spend is attributed to the sender and to nobody else"
given "the proxy's count for $addr_a and $addr_b"
before_a="$(spent_by "$addr_a")"
before_b="$(spent_by "$addr_b")"
when "$a sends one request through the proxy"
code="$(ask_model "$a")"
check "the request reached the endpoint through the proxy" yes "$(case "$code" in 2*|4*) echo yes ;; *) echo "no ($code)" ;; esac)"
if [ "$code" = 401 ]; then
	gated "$a's count moved" "the endpoint refused the credential, so nothing was counted; needs a real one"
else
	check "$a's count moved" moved "$([ "$(spent_by "$addr_a")" != "$before_a" ] && echo moved || echo still)"
fi
check "$b's count did not" still "$([ "$(spent_by "$addr_b")" = "$before_b" ] && echo still || echo moved)"

scenario "A forged source address is dropped at the bridge"
given "root on the machine inside $a's network namespace"
## A cage is not registered with machined, so its leader is found by the
## nspawn that holds it: the one whose argv names the machine, and its child.
pid="$(sshm "pgrep -P \"\$(pgrep -f -- '--machine=$a( |\$)' | head -1)\" 2>/dev/null | head -1")"
check "the actor's cage for $a is running and its leader pid is known" yes "$([ -n "$pid" ] && echo yes || echo no)"
before_b="$(spent_by "$addr_b")"
when "a request leaves $a's veth carrying $b's address"
sshm "nsenter -t '$pid' -n sh -c 'ip addr add $addr_b/32 dev host0 2>/dev/null; curl -s -m 3 --interface $addr_b -o /dev/null -X POST $messages; ip addr del $addr_b/32 dev host0 2>/dev/null'" >/dev/null 2>&1
check "$b's count did not move" still "$([ "$(spent_by "$addr_b")" = "$before_b" ] && echo still || echo moved)"

scenario "The hard limit is the proxy's"
ceiling="$(jq -r '.tokenCeiling // empty' "$(spec_json)")"
given "a token ceiling of ${ceiling:-none} in the spec"
check "a ceiling is declared" yes "$([ -n "$ceiling" ] && echo yes || echo no)"
when "$a sends requests until the proxy refuses"
code=""
for _ in $(seq 1 50); do
	code="$(ask_model "$a")"
	case "$code" in 429 | 401) break ;; esac
done
if [ "$code" = 401 ]; then
	gated "the proxy answers 429 at the hard limit" "the endpoint refused the credential, so no spend reaches the ceiling; needs a real one"
else
	check "the proxy answers 429 at the hard limit" 429 "$code"
fi

scenario "The machine's daemon substitutes and never fetches (ADR-025 point 5, ADR-057 point 6)"
when "the machine is asked for a path the cache has, and for a derivation that fetches"
check "a host path is valid to the machine's store, through the overlay" "yes" \
	"$(sshm "nix-store --query --requisites /run/current-system | head -1 | grep -q /nix/store && echo yes")"
check "a fixed-output derivation does not build here" "refused" \
	"$(sshm 'nix build --no-link --impure --expr "builtins.fetchurl { url = \"https://example.com/\"; sha256 = \"0000000000000000000000000000000000000000000000000000\"; }" >/dev/null 2>&1 && echo built || echo refused')"
check "a second render substituted nothing" 0 \
	"$(sshm 'fabriek-container factory-render 2>&1 | grep -c "copying path"')"

bash fabriek down "$F"
exit "$fail"
