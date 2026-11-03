#!/usr/bin/env bash
## ADR-072's proof, which needs a host, a running factory and a real token
## and so cannot be a bats test: a factory's pi reaches the company AI
## gateway through the proxy, a token pushed by rename reaches the proxy
## without a restart, and nothing in a cage can read it.
##
## Wants the factory F running on this host with the gateway as its only or
## first allowed endpoint (egress = [ "zd-gateway" ]), a role to ask from,
## and the Mac's push (modules/programs/zd-claude/fabriek-push.nix in the
## operator's NixOS configuration) to have written the credential file at
## least once. Run as the operator who owns the credential directory:
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   F=example ROLE=backend tests/manual/gateway.sh
##
## The credential file's value is never printed, and the push below copies
## the file onto itself rather than minting a token.
# shellcheck disable=SC2016
set -uo pipefail
F="${F:-example}"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"
ROLE="${ROLE:-backend}"

ENDPOINTS="$(onhost "cat '$ETC/endpoints.json'")"
## The one endpoint whose credential travels in Authorization and has a
## limit: the gateway. A host with no maxAge is not the one under proof.
HOST="$(jq -r '(.maxAge // {}) | keys[0] // empty' <<<"$ENDPOINTS")"
[ -n "$HOST" ] || {
	echo "the factory $F reaches no endpoint that declares a maxAge; allow the gateway in its egress"
	exit 1
}
MODEL="$(jq -r --arg h "$HOST" '.models[$h]' <<<"$ENDPOINTS")"
PROXY="$(onhost "jq -r .proxy '$ETC/bridge.json'")"
DIR="${FABRIEK_CREDENTIALS_DIR:-/var/lib/fabriek-credentials}"
FILE="$DIR/${GATEWAY_FILE:-zd-gateway}"
STAMP="$STATE/egress-age/$HOST"

## One short turn, asked from the role's cage the way pi asks: the
## placeholder key as x-api-key, which the proxy clears, and no credential.
turn() {
	in_cage "$ROLE" curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
		-H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -H 'x-api-key: fabriek' \
		-d "{\"model\":\"$MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}]}" \
		"http://$PROXY/$HOST/v1/messages"
}
stamp_mtime() { onhost "stat -c %Y '$STAMP' 2>/dev/null || echo none"; }
## The operator's own push: the file onto a temporary name and renamed over
## itself, which is what the Mac does with a new token.
push() { cp "$FILE" "$DIR/.push.new" && mv "$DIR/.push.new" "$FILE"; }
spend_total() { in_cage "$ROLE" curl -s --max-time 10 "http://$PROXY/status" | jq -r '.total // 0'; }

wait_cages "$ROLE" || {
	echo "the role $ROLE of $F has no cage"
	exit 1
}

scenario "A turn against the gateway goes through the proxy and answers 200"
given "$F allows $HOST and its credential was pushed from the Mac"
when "the $ROLE role sends one short request on the placeholder key"
check "the gateway answers 200" "200" "$(turn)"

scenario "A push by rename reaches the proxy within a minute, without a restart"
before_nginx="$(onhost "systemctl show nginx.service -p InvocationID --value")"
before="$(stamp_mtime)"
given "the stamp says the credential was filed at $before"
when "the operator renames a file into $DIR"
push
# shellcheck disable=SC2329  # invoked through eventually
moved() { [ "$(stamp_mtime)" != "$before" ] && echo moved; }
check "the stamp moves" "moved" "$(eventually 60 moved moved)"
check "nginx was reloaded and not restarted" "$before_nginx" "$(onhost "systemctl show nginx.service -p InvocationID --value")"
check "the proxy's header file carries the file's value" "yes" \
	"$(onhost "cmp -s <(sed -n 's/^proxy_set_header [^ ]* \"\(.*\)\";\$/\1/p' '/run/fabriek-egress/$F/$HOST.conf' | tr -d '\n') '$FILE' && echo yes")"
check "a turn after it answers 200" "200" "$(turn)"

scenario "A push in the middle of a turn leaves its connection open and the spend where it was"
given "a request in flight, and the spend counted so far"
total_before="$(spend_total)"
(turn >"$S/inflight.code") &
inflight=$!
sleep 1
when "the operator pushes again while it runs"
push
wait "$inflight"
check "the request in flight finished 200" "200" "$(cat "$S/inflight.code")"
total_after="$(spend_total)"
check "the spend count did not reset" "yes" "$([ "${total_after:-0}" -ge "${total_before:-0}" ] && echo yes)"
check "the next request answers 200" "200" "$(turn)"

scenario "fabriek ps says how long ago the credential was filed"
age_line="$(bash fabriek ps 2>/dev/null | grep -F "credential $HOST" | head -1)"
check "it names the host and an age under forty-five minutes" "yes" \
	"$(printf '%s' "$age_line" | grep -Eq "refreshed ([0-9]+s|([0-9]|[0-3][0-9]|4[0-4])m) ago" && echo yes)"

scenario "No role can read the credential"
when "a role asks for the file and the host's copy"
check "the role finds no copy of it" "no" "$(in_cage "$ROLE" sh -c "test -e '$STATE/egress/$HOST' && echo yes || echo no")"
check "the operator cannot read the proxy's copy" "denied" "$(cat "$STATE/egress/$HOST" >/dev/null 2>&1 && echo readable || echo denied)"

exit "$fail"
