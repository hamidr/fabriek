# shellcheck shell=bash
## What every manual proof needs before it can ask a factory anything: the
## scratch directory the operator named, the environment that points fabriek
## at it, a way to run a command as root on this host with one factory's
## facts loaded (ADR-067), and a checker that says which step failed and what
## it saw.
##
## Sourced, never run. A script says which factory it is about by setting F
## before sourcing, and gets onhost, in_cage, wait_cages, check, scenario
## and eventually. The proofs run on the NixOS host the factory is declared
## on: services.fabriek carries the factory, and this file reads its facts
## from where the host wrote them.

cd "${FABRIEK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}" || exit 1
S="${FABRIEK_PROOF_DIR:?set FABRIEK_PROOF_DIR to a scratch directory}"
export FABRIEK_LIB="$PWD/modules" FABRIEK_SELF="$PWD"
F="${F:-acme}"
FACTS="${FABRIEK_FACTORIES:-/etc/fabriek/factories}/$F.env"
[ -f "$FACTS" ] || {
	echo "the factory $F is not declared on this host: no $FACTS"
	exit 1
}
## The factory's facts, for the proof's own reading: where its state and
## its rendered files are, and its bridge.
fact() { sed -n "s/^$1=//p" "$FACTS"; }
# shellcheck disable=SC2034  # read by the scripts that source this
STATE="$(fact FABRIEK_STATE)"
ETC="$(fact FABRIEK_ETC)"
# shellcheck disable=SC2034
BRIDGE="$(fact FABRIEK_BRIDGE)"
## The factory's nixcage machine (ADR-070), or nothing where its roles are
## the host's cages.
MACHINE="$(fact FABRIEK_MACHINE)"
mkdir -p "$S"

## A command as root on this host, with the factory's facts in its
## environment, the way the units and the machine program have them.
onhost() {
	sudo env "FABRIEK_FACTORY=$F" "FABRIEK_LIB=$FABRIEK_LIB" bash -c "set -a; . '$FACTS'; set +a; $*"
}

## nixcage over one of this factory's cages, through its machine when it
## has one: the verbs read the same either way (nixcage ADR-026).
cage_verb() {
	local verb="$1"
	shift
	onhost "nixcage-container $verb ${MACHINE:+--machine $MACHINE} $*"
}

## A script, read on stdin, run as root where the factory's cages are: its
## machine, or this host. Stdin rather than argv, since a script crossing
## sudo, bash -c and ssh would be quoted three times.
where_cages_are() {
	if [ -n "$MACHINE" ]; then
		onhost "nixcage-container machine exec $MACHINE bash -s"
	else
		onhost "bash -s"
	fi
}

## What the factory is, as render wrote it: the clamped declaration under
## .declaration, with the two fields the proofs read beside it. Fetched
## once per run, and a run starts without the last run's copy.
rm -f "$S/spec.json"
spec_json() {
	if [ ! -s "$S/spec.json" ]; then
		onhost "cat '$ETC/declaration.json'" 2>/dev/null |
			jq '{declaration: ., egress: .resources.egress, tokenCeiling: .resources.tokens}' >"$S/spec.json" 2>/dev/null ||
			rm -f "$S/spec.json"
	fi
	printf '%s\n' "$S/spec.json"
}

## Waits up to WAIT_CAGES seconds (default 120) for the executor to hold a
## cage for each role named, and for each to answer a command. up returns
## before the sessions are started, and a hand session entered in that
## window meets the actor's cage being made under the same name (seen
## 2026-09-16: one role with no address); a microVM's scope runs while
## its guest still boots, and a hand entered then gets nothing back (seen
## 2026-09-22: a role with no address, again).
cages_present() {
	local role
	for role in "$@"; do
		cage_verb status "'$F-$role'" 2>/dev/null | grep -q '^running' || return 1
		[ "$(in_cage "$role" echo up)" = up ] || return 1
	done
}
wait_cages() {
	local _i
	for _i in $(seq 1 "${WAIT_CAGES:-120}"); do
		cages_present "$@" && return 0
		sleep 1
	done
	return 1
}

## Runs a command as one role of this factory, inside its cage, and prints
## what it printed. The session is the real one, so what this sees is what a
## role sees.
in_cage() {
	local role="$1"
	shift
	bash fabriek -f "$F" enter "$role" -- "$@" 2>/dev/null
}

# shellcheck disable=SC2034  # read by the script that sources this
fail=0
## A Then. What came back has crossed a container's stdout and can carry a
## carriage return that makes two identical strings report as different, so
## it is trimmed before comparing.
check() {
	local what="$1" want="$2" got="$3"
	got="$(printf '%s' "$got" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	if [ "$got" = "$want" ]; then
		echo "  ok   $what"
	else
		echo "  FAIL $what: wanted '$want', got '$got'"
		# shellcheck disable=SC2034  # read by the script that sources this
		fail=1
	fi
}

## A Then that cannot be asked here, and says why: a step that needs what the
## proof was not given (a real credential, say) is named rather than failed,
## so that the transcript says what was proved and what was not.
gated() { printf '  GATED %s: %s\n' "$1" "$2"; }

## A Given and a When, printed so the transcript reads as the scenario. A
## proof that stops halfway leaves the last scenario named.
scenario() { printf '\n%s\n' "$1"; }
given() { printf '  Given %s\n' "$1"; }
when() { printf '  When  %s\n' "$1"; }

## Polls a command until its output equals what is wanted or the wait runs
## out, printing the last output. For Thens that follow an actor's work.
eventually() {
	local seconds="$1" want="$2" got=""
	shift 2
	local _i
	for _i in $(seq 1 "$seconds"); do
		got="$("$@" 2>/dev/null | tr -d '\r')"
		[ "$got" = "$want" ] && break
		sleep 1
	done
	printf '%s' "$got"
}
