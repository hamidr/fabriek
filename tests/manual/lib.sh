# shellcheck shell=bash
## What every manual proof needs before it can ask a machine anything: the
## scratch directory the operator named, the environment that points fabriek
## at it, a way to reach one factory's machine, and a checker that says which
## step failed and what it saw.
##
## Sourced, never run. A script says which factory it is about by setting F
## before sourcing, and gets D (the machine's directory), sshm, wait_ssh, check
## and scenario. The scripts that predate this file carry their own copies;
## they are replaced rather than migrated, because what they prove is
## replaced too (docs/roadmap.md phases 2 and 5).

cd "${FABRIEK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}" || exit 1
S="${FABRIEK_PROOF_DIR:?set FABRIEK_PROOF_DIR to a scratch directory}"
export FABRIEK_MACHINES="$S/machines" FABRIEK_CONFIG="$S/cfg.toml" \
	FABRIEK_LIB="$PWD/modules" FABRIEK_SELF="$PWD"
F="${F:-acme}"
D="$S/machines/$F"

sshm() {
	ssh -i "$D/id_ed25519" -p "$(cat "$D/port")" -o UserKnownHostsFile="$D/known_hosts" \
		-o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o BatchMode=yes \
		-o ConnectTimeout=3 root@localhost "$@"
}

## Waits up to WAIT_SSH seconds (default 180) for the machine to answer.
wait_ssh() {
	local _i
	for _i in $(seq 1 "${WAIT_SSH:-180}"); do
		sshm true 2>/dev/null && return 0
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
## A Then. What came back has crossed ssh and a container's stdout and can
## carry a carriage return that makes two identical strings report as
## different, so it is trimmed before comparing.
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
