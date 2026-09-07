#!/usr/bin/env bash
## ADR-027's measurement plan, which needs a real machine and so cannot be a
## bats test.
##
## Every number that document depends on is measured here rather than guessed,
## because a rate read off a probe list is a rate that will be wrong by an
## order of magnitude in whichever direction is inconvenient. Three sources
## record what a factory does -- the loop's tap, the egress proxy and the guest
## kernel -- and this asks each of them what it costs.
##
## Wants a factory already running, with a role declared and a repository
## registered, the way tests/manual/stop-and-start.sh does. The attribution
## check needs a role whose declaration names no command, because a declared
## command wins over anything a caller passes and this has to run one of its
## own to see which uid journald stamps on it:
##
##   export CAGEWORKS_PROOF_DIR=/tmp/cageworks-proof
##   tests/manual/observe.sh              # all four
##   tests/manual/observe.sh rate 120     # entries per second, by source
##   tests/manual/observe.sh storage      # what the ledger holds, compressed
##   tests/manual/observe.sh overhead     # the probes' cost, three runs each
##   tests/manual/observe.sh attribution  # the two claims that cross a userns
##
## The retention window in the declaration's schema is set from what 'storage'
## reports against cageworks.machine.diskSize. Until that number exists the
## quota is the only bound, which is why this script comes before it.
set -uo pipefail
cd "${CAGEWORKS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 1
S="${CAGEWORKS_PROOF_DIR:?set CAGEWORKS_PROOF_DIR to a scratch directory}"
export CAGEWORKS_MACHINES="$S/machines" CAGEWORKS_CONFIG="$S/cfg.toml" \
	CAGEWORKS_LIB="$PWD/modules" CAGEWORKS_SELF="$PWD"
F="${CAGEWORKS_FACTORY:-acme}"
R="${CAGEWORKS_ROLE:-builder}"
D="$S/machines/$F"

sshm() {
	ssh -i "$D/id_ed25519" -p "$(cat "$D/port")" -o UserKnownHostsFile="$D/known_hosts" \
		-o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o BatchMode=yes \
		-o ConnectTimeout=3 root@localhost "$@"
}

## Entries in the factory's journal over a window, for one journalctl matcher.
## Counted on the machine, because moving them here to count them would measure
## the transport instead.
entries_since() {
	local window="$1" match="$2"
	sshm "journalctl --namespace=$F --since=-${window}s $match --no-pager -q 2>/dev/null | wc -l"
}

## Per second, to two places, without pulling in a calculator.
per_second() {
	local count="$1" window="$2"
	awk -v c="${count:-0}" -v w="$window" 'BEGIN { printf "%.2f", (w > 0 ? c / w : 0) }'
}

## What each source is, in the journal's own terms. The kernel's account is a
## unit, the proxy's is a syslog tag, and a role's own is whatever is left:
## entries journald stamped with a uid that is not the machine's.
cmd_rate() {
	local window="${1:-60}"
	echo "sampling $F for ${window}s"
	sleep "$window"

	local kernel proxy ledger
	kernel="$(entries_since "$window" "_SYSTEMD_UNIT=cageworks-probes.service")"
	proxy="$(entries_since "$window" "SYSLOG_IDENTIFIER=cageworks-egress")"
	ledger="$(entries_since "$window" "_UID=$(role_uid)")"

	echo "kernel: ${kernel:-0} entries, $(per_second "$kernel" "$window")/s"
	echo "proxy:  ${proxy:-0} entries, $(per_second "$proxy" "$window")/s"
	echo "ledger: ${ledger:-0} entries, $(per_second "$ledger" "$window")/s"
}

## What the ledger actually holds. logicalused against used is the compression
## the retention window has to be read against: a window set from the logical
## number would be wrong by the compressratio.
cmd_storage() {
	sshm "zfs get -Hp used,logicalused,compressratio cageworks-$F/state/journal" ||
		echo "no dataset: the pool gave the ledger a plain directory, so there is no bound to read"
	sshm "journalctl --namespace=$F --disk-usage"
}

## The uid nixcage allocated for this role, asked for rather than assumed. It
## is the number both attribution checks are about.
role_uid() {
	sshm "nixcage-container uid $R" 2>/dev/null
}

## A fixed workload, run on the machine. Execs, because exec is what two of the
## three probes are on and what a role session does constantly.
workload() {
	# shellcheck disable=SC2016  # runs in the guest, expands there
	sshm 'a=$(date +%s%N)
	  for i in $(seq 1 3000); do /run/current-system/sw/bin/true; done
	  b=$(date +%s%N); echo $(( (b - a) / 1000000 ))'
}

## What the probes cost, measured rather than asserted. The RSS and the CPU
## come out of the memory and the cores the declaration asked for and the
## operator allowed, so this is a bill and not a curiosity.
cmd_overhead() {
	local i ms
	sshm "systemctl stop cageworks-probes" >/dev/null 2>&1
	for i in 1 2 3; do
		ms="$(workload)"
		echo "without probes, run $i: ${ms}ms"
	done

	sshm "systemctl start cageworks-probes" >/dev/null 2>&1
	## bpftrace attaches before it reports anything, and a run started during
	## the attach measures the attach.
	sleep 10
	for i in 1 2 3; do
		ms="$(workload)"
		echo "with probes, run $i: ${ms}ms"
	done
	echo "probe peak RSS: $(sshm "systemctl show cageworks-probes -p MemoryPeak --value") bytes"
}

## The two claims that cross a user namespace, checked rather than assumed.
## They are the same claim from two directions, and neither is worth asserting
## from a header file: that journald stamps a caged writer with the uid nixcage
## allocated, and that a kernel probe reports the number ADR-025's meta skuid
## filters on.
cmd_attribution() {
	local uid
	uid="$(role_uid)"
	if [ -z "$uid" ]; then
		echo "attribution: no uid for role $R; nothing to check against"
		return 1
	fi
	echo "nixcage allocated uid $uid to $R"

	## Written from inside the cage, through the socket the session was given.
	## A role whose declaration names a command runs that instead, and the
	## check will report nothing stamped rather than the wrong thing.
	nix develop --command bash cageworks role "$F" "$R" -- \
		systemd-cat -t cageworks-attribution echo "an entry written from inside a cage" \
		>/dev/null 2>&1

	## -o export rather than json, because reading a field out of it needs
	## nothing on the machine that is not systemd.
	local stamped
	stamped="$(sshm "journalctl --namespace=$F -t cageworks-attribution -n 1 -o export --no-pager -q |
		sed -n 's/^_UID=//p'")"
	if [ "$stamped" = "$uid" ]; then
		echo "journald stamped the caged writer $stamped: agrees"
	else
		echo "journald stamped '$stamped', nixcage allocated '$uid': DISAGREES"
		return 1
	fi

	local seen
	seen="$(sshm "journalctl --namespace=$F -u cageworks-probes --since=-120s --no-pager -q |
		grep -c \"uid=$uid \"")"
	if [ "${seen:-0}" -ge 1 ]; then
		echo "the kernel reported $seen events for uid $uid: agrees"
	else
		echo "the kernel reported nothing for uid $uid: DISAGREES"
		return 1
	fi
}

case "${1:-all}" in
rate) cmd_rate "${2:-60}" ;;
storage) cmd_storage ;;
overhead) cmd_overhead ;;
attribution) cmd_attribution ;;
all)
	cmd_attribution
	cmd_rate "${2:-60}"
	cmd_storage
	cmd_overhead
	;;
*)
	echo "usage: observe.sh [rate [seconds] | storage | overhead | attribution]" >&2
	exit 1
	;;
esac
