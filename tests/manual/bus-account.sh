#!/usr/bin/env bash
## ADR-069's account gates, which need the host's one nats-server with two
## factories on it and so cannot be a bats test: a factory's subjects and
## streams are its account's and no other's, a factory's users are read
## again without the server restarting, and a file the server cannot read
## never reaches it.
##
## Wants a NixOS host whose services.fabriek declares two factories, named
## by A and B (default acme and widgets), each with at least one role, and
## a scratch directory. Both are brought up; the second is left running so
## that what happens to the first can be said about it.
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   A=acme B=widgets tests/manual/bus-account.sh
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
## As root on this host with one named factory's facts loaded, the host's
## own path first as a unit has it.
onhost_of() {
	local f="$1"
	shift
	sudo env "FABRIEK_FACTORY=$f" "FABRIEK_LIB=$FABRIEK_LIB" \
		"PATH=/run/current-system/sw/bin:$PATH" \
		bash -c "set -a; . '$FACTS_DIR/$f.env'; set +a; $*"
}
state_a="$(fact_of "$A" FABRIEK_STATE)"
state_b="$(fact_of "$B" FABRIEK_STATE)"
etc_a="$(fact_of "$A" FABRIEK_ETC)"
url_a="nats://$(fact_of "$A" FABRIEK_BRIDGE_HOST):$(fact_of "$A" FABRIEK_BUS_PORT)"
url_b="nats://$(fact_of "$B" FABRIEK_BRIDGE_HOST):$(fact_of "$B" FABRIEK_BUS_PORT)"

bash fabriek up "$A" || exit 1
bash fabriek up "$B" || exit 1

## natscli as one factory's user, from the host: the password is read there
## and reaches the tool in its environment, never on this script's command
## line.
# shellcheck disable=SC2016  # the password expands on the host, not here
as() {
	local factory="$1" state="$2" url="$3" user="$4"
	shift 4
	sudo bash -c "NATS_URL='$url' NATS_USER='$factory-$user' NATS_PASSWORD=\"\$(cat '$state/bus/$user')\" nats $*" 2>&1
}
as_a() { as "$A" "$state_a" "$url_a" "$@"; }
as_b() { as "$B" "$state_b" "$url_b" "$@"; }

scenario "A factory's streams are its account's, and no other factory's"
given "both factories up on the host's one server"
check "$A's executor sees its own streams" yes \
	"$(as_a executor stream ls --json | jq -r 'if . == null then "no" else (if all(.[]; test("^(mailbox|control|events)-|^(findings|commands|operator|probes)$")) then "yes" else "no" end) end')"
check "and one of them is its own role's mailbox" yes \
	"$(as_a executor stream ls --json | jq -r --arg s "mailbox-$(jq -r '.declaration.roles | keys[0]' "$(spec_json)")" 'if . == null then "no" else (if index($s) then "yes" else "no" end) end')"
when "$A's executor lists them beside the name $B holds its own role's under"
b_role="$(sudo bash -c "jq -r '.roles | keys[0]' '$(fact_of "$B" FABRIEK_ETC)/declaration.json'")"
check "$B's role's mailbox is not among them" yes \
	"$(as_a executor stream ls --json | jq -r --arg s "mailbox-$b_role" 'if . == null then "yes" else (if index($s) then "no" else "yes" end) end')"

scenario "What one factory says reaches nothing of the other's"
given "a subscriber in $B's account on every subject it may hear"
sub_log="$S/bus-cross-account.log"
as_b executor sub '">"' --count 1 --timeout 8s >"$sub_log" 2>&1 &
sub_pid=$!
when "$A publishes on a subject both accounts have"
as_a executor pub operator '{"json":"crossing"}' >/dev/null
wait "$sub_pid"
check "$B's subscriber heard nothing" yes "$(grep -q crossing "$sub_log" && echo no || echo yes)"

scenario "One factory's users are read again without the server restarting"
given "the server's pid and $B's connections"
pid_before="$(systemctl show -p MainPID --value nats.service)"
when "$A prepares, which writes its users and asks for a reload"
onhost_of "$A" "fabriek-container factory-prepare '$A'" >/dev/null 2>&1
check "the server was not restarted" "$pid_before" "$(systemctl show -p MainPID --value nats.service)"
check "$B may still speak on its own account" yes \
	"$(as_b executor pub operator '{"json":"still here"}' | grep -q "Published" && echo yes || echo no)"

scenario "A file the server cannot read never reaches it, and one that did is repaired by the next up"
given "$A's include made malformed by hand, which is not how a factory writes it"
users_file="$etc_a/nats-users.conf"
sudo cp "$users_file" "$S/nats-users.conf.kept"
sudo bash -c "printf 'users = [ { user: \"broken\"\n' >'$users_file'"
when "$B prepares while that file is still on the host"
## One server reads one configuration, so a file nobody has repaired holds
## up every factory's reload: $B's users are written and the reload is
## refused, naming the configuration rather than $B. Prepare is asked
## rather than up, because up also renders and reloads what is not the
## bus's, and this is about the bus.
prepare_b="$(onhost_of "$B" "fabriek-container factory-prepare '$B'" 2>&1)"
check "$B's prepare is refused at the reload" yes "$(grep -q "nothing was reloaded" <<<"$prepare_b" && echo yes || echo no)"
check "and the refusal says where to look" yes "$(grep -q "another factory's users" <<<"$prepare_b" && echo yes || echo no)"
check "the server is still the one that was running" "$pid_before" "$(systemctl show -p MainPID --value nats.service)"
when "$A prepares, which renders its users again"
prepare_a="$(onhost_of "$A" "fabriek-container factory-prepare '$A'" 2>&1)"
check "$A is prepared" yes "$(grep -q "$A: prepared" <<<"$prepare_a" && echo yes || echo no)"
check "the file the server reads is one it can read" yes \
	"$(sudo nats-server -t -c /var/lib/fabriek/nats.conf >/dev/null 2>&1 && echo yes || echo no)"
when "$B prepares again"
prepare_b="$(onhost_of "$B" "fabriek-container factory-prepare '$B'" 2>&1)"
check "$B is prepared" yes "$(grep -q "$B: prepared" <<<"$prepare_b" && echo yes || echo no)"

scenario "An account's memory is its own, and one factory cannot spend another's"
given "$A's account bounded at the host's build, and $B's beside it"
## Published in one process, a megabyte at a time, until the account's
## JetStream memory is gone: what the bound is for is that a factory
## filling its own bus does not fill anyone else's.
when "$A publishes past what its account may hold, and waits for each ack"
## natscli makes each message itself, a hundred kilobytes of random text
## at a time, so nothing of this size crosses a command line; published to
## JetStream, so what comes back is the stream's answer and not a publish
## nobody acknowledged.
last=""
for _i in $(seq 1 40); do
	last="$(as_a executor pub operator --jetstream --count 50 "'{{ Random 100000 100000 }}'" 2>&1 | tail -2)"
done
## A stream at the account's bound discards its oldest rather than refusing
## (every stream here is discard: old), so the publisher is answered and
## the account stops growing. What the bound is for is that a factory
## filling its own bus fills nobody else's.
check "the publisher is answered rather than refused" yes \
	"$(grep -q "insufficient resources\|resources exceeded" <<<"$last" && echo no || echo yes)"
check "and the account's memory is at the bound the host set" yes \
	"$(as_a executor account info | grep -qE "Memory: 128 MiB of 128 MiB" && echo yes || echo no)"
check "$B's account is not where $A's is" yes \
	"$(as_b executor account info | grep -qE "Memory: 0 B of 128 MiB|Memory: [0-9.]+ [KM]iB of 128 MiB" && echo yes || echo no)"
check "$B may still publish on its own account" yes \
	"$(as_b executor pub operator '{"json":"unbothered"}' | grep -q Published && echo yes || echo no)"
## The streams go with the factory: brought down and up, the executor
## makes them again and what was published here is gone.
bash fabriek down "$A" >/dev/null 2>&1
bash fabriek up "$A" >/dev/null 2>&1

bash fabriek down "$B"
bash fabriek down "$A"
exit "$fail"
