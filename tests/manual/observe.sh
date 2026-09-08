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
##   tests/manual/observe.sh subjects     # the block a role principal holds
##   tests/manual/observe.sh containment  # what cage root can and cannot reach
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

## The base of the block nixcage allocated this role, asked for rather than
## assumed.
role_uid() {
	sshm "nixcage-container uid $R" 2>/dev/null
}

## The number inside that block the agent runs as. It is the one every host
## file the session touches belongs to, and the one both other sources see.
agent_uid() {
	sshm "nixcage-container uid $R agent" 2>/dev/null
}

## A principal holds a block, not a number. Cage root sits at the base and the
## agent at the next one, so that a supervisor and the program it supervises
## are not one principal.
cmd_subjects() {
	local base agent
	base="$(role_uid)"
	agent="$(agent_uid)"
	if [ -z "$base" ] || [ -z "$agent" ]; then
		echo "subjects: no block for $R; the machine may declare no subjects"
		return 1
	fi
	echo "cage root: $base"
	echo "agent:     $agent"
	if [ "$((agent - base))" -eq 1 ]; then
		echo "the agent is the number after cage root: agrees"
	else
		echo "the agent is $((agent - base)) past cage root, not 1: DISAGREES"
		return 1
	fi
}

## nixcage's own ADR-010 point 7, which everything about separating the loop
## from the agent rests on and which that document says plainly is reasoned
## rather than measured: cage root keeps CAP_SETUID over its own block and
## reaches nothing beyond it.
##
## Asked of the primitive directly rather than through a role session, because
## a role session now always names the subject and this is a question about the
## session that does not.
cmd_containment() {
	local base project
	base="$(role_uid)"
	[ -n "$base" ] || { echo "containment: no uid for $R"; return 1; }

	## nixcage evaluates the project's flake on the way in, so this needs a
	## real project on the machine and not a bare directory. The factory's own
	## clone is one; until PRD-004 phase 3 shares the repository in there is
	## none, and CAGEWORKS_PROBE_PROJECT names one put there by hand.
	project="${CAGEWORKS_PROBE_PROJECT:-/var/lib/nixcage/clones/$F}"
	if ! sshm "[ -f $project/flake.nix ]" 2>/dev/null; then
		echo "containment: no project with a flake at $project on the machine"
		echo "  set CAGEWORKS_PROBE_PROJECT, or wait for the clone to exist"
		return 1
	fi

	## The subject has to work before anything it buys can be measured. This
	## is separated from the two checks below so that a nixcage that cannot
	## enter as a subject reports that, rather than reading as cage root
	## failing to reach its own block.
	if ! sshm "nixcage-container enter --uid $base --user $R --subject agent \
		$F-$R $project true" >/dev/null 2>&1; then
		echo "containment: this nixcage cannot enter as a subject at all"
		return 1
	fi

	## By store path, because the cage's profile carries no util-linux and the
	## store is bound into every session. Resolved on the machine rather than
	## written here: which build of it is there is not this script's business.
	local setpriv
	# shellcheck disable=SC2016  # runs in the guest, expands there
	setpriv="$(sshm 'readlink -f $(command -v setpriv)' 2>/dev/null)"
	if [ -z "$setpriv" ]; then
		echo "containment: no setpriv on the machine to drop with"
		return 1
	fi

	## Inside the cage the block maps from container uid 0 upward, so cage
	## root is 0, the agent is 1, and 2 is the neighbour's.
	if sshm "nixcage-container enter --uid $base --user $R $F-$R $project \
		$setpriv --reuid=1 --clear-groups true" >/dev/null 2>&1; then
		echo "cage root reaches its own subject: agrees"
	else
		echo "cage root cannot reach its own subject: DISAGREES"
		return 1
	fi

	if sshm "nixcage-container enter --uid $base --user $R $F-$R $project \
		$setpriv --reuid=2 --clear-groups true" >/dev/null 2>&1; then
		echo "cage root reached a uid past its block: DISAGREES"
		return 1
	fi
	echo "cage root reaches nothing past its block: agrees"
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
	## The agent's number and not the block's base. A session runs as the
	## agent, so that is what journald reads off SO_PEERCRED and what the
	## kernel reports for the exec (ADR-028). A run where these come back as
	## the base is a run where the subject did not take effect.
	local uid
	uid="$(agent_uid)"
	if [ -z "$uid" ]; then
		echo "attribution: no agent uid for role $R; nothing to check against"
		return 1
	fi
	echo "nixcage allocated uid $uid to the agent of $R"

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
subjects) cmd_subjects ;;
containment) cmd_containment ;;
all)
	cmd_subjects
	cmd_containment
	cmd_attribution
	cmd_rate "${2:-60}"
	cmd_storage
	cmd_overhead
	;;
*)
	echo "usage: observe.sh [rate [seconds] | storage | overhead | attribution | subjects | containment]" >&2
	exit 1
	;;
esac
