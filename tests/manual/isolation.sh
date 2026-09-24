#!/usr/bin/env bash
## ADR-037's measurement plan on the host a factory is declared on (ADR-067),
## which needs cages and a bridge for real and so cannot be a bats test.
##
## Wants a NixOS host with the factory in services.fabriek, a scratch
## directory, and a repository declaring a factory called acme with at least
## two roles, an egress ceiling that allows one host, a credential for it,
## and a token ceiling small enough to reach in a handful of requests. For
## the substrate scenario, one role declared `substrate = "microvm"` and
## nixcage.microvm.enable on the host; without it that scenario is gated.
## For the forward scenario, run once with docker enabled on the host, so
## ip_forward is set and its FORWARD chain present.
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   tests/manual/isolation.sh
##
## What the host must offer for these to pass, and where each is decided:
## a bridge per factory (modules/host/bridge.nix); one port per cage carrying
## one address (nixcage ADR-015); the proxy on the bridge answering /status
## with a JSON object of tokens spent per source address
## (modules/host/proxy.nix); a forward chain dropping anything from or to a
## factory's bridge (the same); nixcage dropping a frame whose source is not
## its port's address (nixcage ADR-064).
set -uo pipefail
F="${F:-acme}"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"

run_start="$(date '+%Y-%m-%d %H:%M:%S')"
bash fabriek up "$F" || exit 1

## The bridge, proxy and forged-source scenarios enter an nspawn cage's
## network namespace from the host, which a microVM has none of (nixcage
## ADR-019), so the first role is one on nspawn; the substrate scenario
## below asks the microVM role its own questions. The second role is any
## other, since it is only asked for its address and to be unreachable.
roles="$(jq -r '.declaration.roles | to_entries | sort_by(.key)
	| (map(select((.value.substrate // "nspawn") == "nspawn")) + map(select(.value.substrate == "microvm")))
	| .[].key' "$(spec_json)" 2>/dev/null)"
a="$(printf '%s\n' "$roles" | sed -n 1p)"
b="$(printf '%s\n' "$roles" | sed -n 2p)"
if [ -z "$a" ] || [ -z "$b" ]; then
	echo "acme declares fewer than two roles, so cage-to-cage cannot be asked"
	bash fabriek down "$F"
	exit 1
fi
wait_cages "$a" "$b" || {
	echo "the actors' cages for $a and $b never came up"
	bash fabriek down "$F"
	exit 1
}
## The factory's bridge, from its facts (modules/host/bridge.nix).
bridge="$BRIDGE"

## The executor keeps one session per role, and a cage is one veth and one
## address on the bridge under the role's name. A hand session joins the
## running cage's network (nixcage ADR-011 point 5), so this proof asks its
## questions beside the actors rather than in their place.

## The address a role's cage was given, read from inside the cage through
## the kernel's own table: a cage carries no ip, and /proc/net/fib_trie
## lists a namespace's local addresses as /32 entries under LOCAL.
addr_of() { in_cage "$1" cat /proc/net/fib_trie | tr -d '\r' | awk '/\/32 host LOCAL/ {print a} {a=$2}' | grep -v '^127\.' | sort -u | head -1; }
## One HTTP request from inside a cage over bash's /dev/tcp, since a cage
## carries no curl: prints the status code, or nothing when nothing
## answered. The body is read to its end, or the proxy's filter never sees
## the usage it counts (resp=0 in its log). On one line: nixcage-container exec keeps an argument's first
## line only (seen 2026-09-16). http <role> <host:port> <method> <path> [body]
# shellcheck disable=SC2016  # expands in the cage
http() {
	local role="$1" hostport="$2" method="$3" path="$4" body="${5:-}"
	in_cage "$role" bash -c 'exec 3<>"/dev/tcp/${1%%:*}/${1##*:}" || exit 1; printf "%s %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" "$2" "$3" "$1" "${#4}" "$4" >&3; r=$(cat <&3); printf %s "$r" | head -1 | cut -d" " -f2' _ "$hostport" "$method" "$path" "$body" 2>/dev/null | tr -d '\r'
}
## The interfaces a cage has, from the kernel and not from a tool. Read from
## /proc/net/dev, which is the namespace's own; /sys/class/net in a session
## that joined a namespace by path is the host's sysfs and lists the host's.
interfaces_of() { in_cage "$1" cat /proc/net/dev | tr -d '\r' | tail -n +3 | cut -d: -f1 | tr -d ' ' | grep -v '^lo$' | paste -sd, -; }
## Tokens the proxy has counted for one source address.
spent_by() { curl -s "http://$proxy/status" | jq -r --arg a "$1" '.[$a] // 0'; }

scenario "A cage is on the factory's bridge and nowhere else"
given "a factory that is up and its actors running"
check "the executor is running the actors" active "$(systemctl is-active "fabriek-$F-executor" 2>/dev/null)"
when "a role's cage is entered by hand, beside its actor"
check "the bridge $bridge exists on the host" present \
	"$(ip link show "$bridge" >/dev/null 2>&1 && echo present || echo absent)"
check "role $a sees host0 and nothing else besides lo" host0 "$(interfaces_of "$a")"
addr_a="$(addr_of "$a")"
addr_b="$(addr_of "$b")"
check "role $a holds one global address" yes "$([ -n "$addr_a" ] && echo yes || echo no)"
check "role $b holds a different address" yes "$([ -n "$addr_b" ] && [ "$addr_a" != "$addr_b" ] && echo yes || echo no)"

proxy="$(onhost "cat '$ETC/bridge.json'" 2>/dev/null | jq -r .proxy)"
check "render says where the proxy is on the bridge" yes "$([ -n "$proxy" ] && echo yes || echo no)"
## The proxy's location for a model endpoint is the endpoint's name (ADR-037
## point 3); a request to the provider lands there and leaves with the
## credential the operator holds.
endpoint="$(jq -r '.egress[0] // empty' "$(spec_json)")"
check "the spec allows one endpoint the proxy can be asked for" yes "$([ -n "$endpoint" ] && echo yes || echo no)"
## The provider's own path and shape, and the model the operator named for
## it, so a request that reaches it is answered and counted.
model="$(onhost "sed -n '/^\\[models\\]/,/^\\[/ s/^\"$endpoint\" = \"\\(.*\\)\"/\\1/p' '$ETC/fabriek.toml'" | head -1)"
case "$endpoint" in
api.anthropic.com) messages_path="/$endpoint/v1/messages" ;;
*) messages_path="/$endpoint/v1/chat/completions" ;;
esac
messages="http://$proxy$messages_path"

scenario "A cage has no route off the host"
given "role $a inside its cage"
when "it opens a connection to an address outside the host"
check "the connection fails" refused \
	"$(in_cage "$a" bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && echo connected || echo refused)"
when "it resolves a name"
check "resolution fails" refused \
	"$(in_cage "$a" getent hosts example.com >/dev/null 2>&1 && echo resolved || echo refused)"
## ADR-067: the host may forward for others (docker, libvirt, a VPN), and a
## cage's bridge is dropped in the forward chain beside their tables.
given "the host forwarding for others, or not"
check "ip_forward on the host is $(cat /proc/sys/net/ipv4/ip_forward)" "" ""
check "the fabriek table drops what comes from or goes to an fb-* bridge" yes \
	"$(sudo nft list table inet fabriek 2>/dev/null | grep -q 'iifname "fb-\*" drop' && echo yes || echo no)"
when "$a opens a connection to an address on another interface of the host"
other="$(ip -4 -o addr show scope global | awk '$2 !~ /^fb-/ {print $4}' | cut -d/ -f1 | head -1)"
check "the connection to ${other:-nothing} fails" refused \
	"$([ -z "$other" ] || in_cage "$a" bash -c "exec 3<>/dev/tcp/$other/22" >/dev/null 2>&1 && echo connected || echo refused)"
## The host is on the bridge itself, so its address there is on-link and no
## route stands in the way: only the fabriek table's input chain keeps the
## host's own services (sshd here) from a cage (seen 2026-09-24: :22 answered).
bridge_host="$(fact FABRIEK_BRIDGE_HOST)"
when "$a opens a connection to the host's sshd on the bridge, at $bridge_host"
check "the connection to $bridge_host:22 fails" refused \
	"$(in_cage "$a" timeout 5 bash -c "exec 3<>/dev/tcp/$bridge_host/22" >/dev/null 2>&1 && echo connected || echo refused)"

scenario "A cage cannot reach a peer"
given "roles $a and $b each in their cage, $b at $addr_b"
when "$a opens a connection to $b's address"
check "the connection fails" refused \
	"$(in_cage "$a" bash -c "exec 3<>/dev/tcp/$addr_b/22" >/dev/null 2>&1 && echo connected || echo refused)"
when "$a opens a connection to the proxy"
check "the proxy answers" answered \
	"$(http "$a" "$proxy" GET /status | grep -q '^[0-9]' && echo answered || echo silent)"

## One request to the endpoint, answering the status the endpoint gave.
## Spend is counted from the endpoint's answer, so an endpoint that refuses
## the credential (401) leaves nothing to count, and the two Thens that need
## a count are gated on it rather than failed. The prompt is about two
## hundred tokens, counted whole by the proxy whether the provider cached
## them or not, so that fifty requests spend ten thousand and reach a
## ceiling the decider's first thought leaves standing.
padding="$(printf 'the quick brown fox jumps over the lazy dog %.0s' $(seq 1 30))"
ask_model() {
	http "$1" "$proxy" POST "$messages_path" \
		"{\"model\":\"${model:-probe}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"$padding hi\"}]}"
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
given "root on the host inside $a's network namespace"
## A cage is not registered with machined, so its leader is found by the
## nspawn that holds it: the one whose argv names the cage, and its child.
pid="$(sudo pgrep -P "$(sudo pgrep -f -- "--machine=$F-$a( |\$)" | head -1)" 2>/dev/null | head -1)"
check "the actor's cage for $a is running and its leader pid is known" yes "$([ -n "$pid" ] && echo yes || echo no)"
before_b="$(spent_by "$addr_b")"
when "a request leaves $a's veth carrying $b's address"
sudo nsenter -t "$pid" -n sh -c "ip addr add $addr_b/32 dev host0 2>/dev/null; curl -s -m 3 --interface $addr_b -o /dev/null -X POST $messages; ip addr del $addr_b/32 dev host0 2>/dev/null" >/dev/null 2>&1
check "$b's count did not move" still "$([ "$(spent_by "$addr_b")" = "$before_b" ] && echo still || echo moved)"

scenario "The hard limit is the proxy's"
ceiling="$(jq -r '.tokenCeiling // empty' "$(spec_json)")"
given "a token ceiling of ${ceiling:-none} in the spec"
check "a ceiling is declared" yes "$([ -n "$ceiling" ] && echo yes || echo no)"
when "$a sends requests until the proxy refuses"
## Fifty requests of two hundred tokens each spend ten thousand; a ceiling
## above twice that is one this proof cannot reach and says so. Under it,
## the decider's first thought (6273 tokens seen 2026-09-16) and a second
## on the ready set's change still leave the count-moved Then room.
if [ "${ceiling:-0}" -gt 20000 ]; then
	gated "the proxy answers 429 at the hard limit" "the ceiling is $ceiling tokens; declare one under 20000 for this factory to reach it here"
else
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
fi

## Only where the ceiling was reached: elsewhere the decider is not held.
if [ "$code" = 429 ]; then
	scenario "At the ceiling the executor holds the decider"
	given "the proxy refusing everything"
	## This run's lines only: the journal keeps every run's, and the last
	## run reached the ceiling as well.
	decider_exits() { journalctl -u "fabriek-$F-executor" --since "$run_start" --no-pager 2>/dev/null | grep -c 'session decider exited'; }
	# shellcheck disable=SC2329  # invoked through eventually
	held_said() { journalctl -u "fabriek-$F-executor" --since "$run_start" --no-pager 2>/dev/null | grep -q 'the decider is held' && echo yes || echo no; }
	when "the decider's session meets the 429 and ends"
	check "the executor says the decider is held" yes "$(eventually 120 yes held_said)"
	exits="$(decider_exits)"
	when "forty-five seconds pass"
	sleep 45
	check "no decider session exited since" "$exits" "$(decider_exits)"
	check "the executor is still running" active "$(systemctl is-active "fabriek-$F-executor" 2>/dev/null)"
fi

scenario "A role declared microvm runs in a kernel of its own, and one declared nspawn in the host's (ADR-067 point 4)"
mv_role="$(jq -r '.declaration.roles | to_entries[] | select(.value.substrate == "microvm") | .key' "$(spec_json)" | head -1)"
ns_role="$(jq -r '.declaration.roles | to_entries[] | select((.value.substrate // "nspawn") == "nspawn") | .key' "$(spec_json)" | head -1)"
host_kernel="$(uname -r)"
if [ -n "$ns_role" ]; then
	check "role $ns_role sees the host's kernel $host_kernel" "$host_kernel" "$(in_cage "$ns_role" uname -r)"
fi
if [ -z "$mv_role" ]; then
	gated "a microvm role sees a kernel of its own" "no role declares substrate = \"microvm\"; declare one and set nixcage.microvm.enable"
else
	wait_cages "$mv_role" || true
	check "role $mv_role sees a kernel that is not the host's" yes "$([ "$(in_cage "$mv_role" uname -r)" != "$host_kernel" ] && echo yes || echo no)"
	check "nixcage names a machine scope for $mv_role's cage" yes "$(onhost "nixcage-container status '$F-$mv_role'" 2>/dev/null | grep -q 'machine-' && echo yes || echo no)"
fi
when "the operator's floor is microvm and a role asked for nspawn"
if onhost "grep -q '^substrate = \"microvm\"' '$ETC/fabriek.toml'" 2>/dev/null; then
	check "up printed the clamp for a raised role" yes "$(onhost "cat '$ETC/notes.json'" | grep -q 'raised to microvm' && echo yes || echo no)"
else
	gated "up printed the clamp for a raised role" "no substrate floor in the operator's caps; set caps.substrate = \"microvm\" for this"
fi

bash fabriek down "$F"
exit "$fail"
