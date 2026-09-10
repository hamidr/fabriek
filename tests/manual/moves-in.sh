#!/usr/bin/env bash
## PRD-004 phase 3's exit condition, which needs a real machine and so cannot
## be a bats test.
##
## Nothing had ever run in a factory's machine before this: no clone, no
## worktree, no task. The suite drove the guest program with the transport
## stubbed and the machine was built and booted without either meeting the
## other. This is where they meet.
##
## Four questions, in the order they stop being answerable. The clone reaches
## the machine's own pool from a remote. A role gets a worktree of it, owned by
## the uid nixcage allocated and not by root. A session runs in a cage on that
## worktree and sees the repository. And the invocation that started it is the
## one tests/command/seam.bats asserts whole, so what a role session is did not
## quietly change on the way to the machine.
##
## The origin is a bare repository on the machine itself. A forge origin would
## drag in a credential and a network, and neither is what this is checking:
## ADR-032 makes the machine clone a remote, and a remote on loopback is one.
## Pushing role branches back to a forge is integration's problem and has its
## own key to deliver.
##
##   export CAGEWORKS_PROOF_DIR=/tmp/cageworks-proof
##   tests/manual/moves-in.sh
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
		-o ConnectTimeout=5 root@localhost "$@"
}
wait_ssh() { for _ in $(seq 1 180); do sshm true 2>/dev/null && return 0; sleep 1; done; return 1; }

fail=0
check() {
	local what="$1" want="$2" got="$3"
	## Trimmed, because what comes back has crossed ssh and a container's
	## stdout and can carry a carriage return that makes two identical strings
	## report as different.
	got="$(printf '%s' "$got" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	if [ "$got" = "$want" ]; then
		echo "ok   $what"
	else
		echo "FAIL $what: wanted $want, got $got"
		fail=1
	fi
}

nix develop --command bash cageworks up "$F" >/dev/null 2>&1 || {
	echo "FAIL the machine would not start"
	exit 1
}
wait_ssh || {
	echo "FAIL the machine never answered"
	exit 1
}

## An origin on the machine, carrying the declaration the factory is already
## registered against. Made here rather than assumed, so a run says something
## about this build and not about whatever a previous one left behind.
ORIGIN=/var/lib/nixcage/proof-origin.git
CLONE="/var/lib/nixcage/factories/$F"

## The seed carries a declaration, because the guest reads a factory's
## declaration out of the clone rather than from anything the operator sends.
## A repository with no cageworks output is one the supervisor refuses before
## it gets as far as a worktree, which is correct and is not what this checks.
##
## The role declares no command. A declared one wins over anything a caller
## passes (ADR-020), which is right and makes a role impossible to ask a
## question of: the checks below would run the declaration's command and see
## nothing of their own. tests/manual/observe.sh needs the same thing for the
## same reason.
##
## Stale state from a previous run is removed rather than reused: a clone
## directory that exists but has no commit is skipped by the ensure, and the
## run after it reports a fault that belongs to the run before.
##
## The worktree is emptied and not removed. Asking for it gave a dataset with a
## mountpoint on it (ADR-017), and rm answers "Device or resource busy" to a
## mountpoint. Emptying leaves the dataset for the ensure to fill, which is
## what the ensure is for.
# shellcheck disable=SC2016  # runs in the guest, expands there
sshm "set -e
	rm -rf $ORIGIN /tmp/seed $CLONE
	if [ -d /var/lib/nixcage/worktrees/$F/$R ]; then
		find /var/lib/nixcage/worktrees/$F/$R -mindepth 1 -maxdepth 1 -exec rm -rf {} +
	fi
	git init -q --bare $ORIGIN
	git init -q /tmp/seed
	cd /tmp/seed
	git config user.email proof@invalid
	git config user.name proof
	printf 'a repository a factory works\n' > README.md
	cat > cageworks.nix <<'DECL'
{
  name = \"$F\";
  roles.$R = {
    provides = [ \"build\" ];
  };
}
DECL
	cat > flake.nix <<'FLAKE'
{
  outputs = { self }: { cageworks = import ./cageworks.nix; };
}
FLAKE
	git add -A
	git -c commit.gpgsign=false commit -qm 'first'
	git remote add origin $ORIGIN
	git push -q origin HEAD:refs/heads/main
	## The bare repo's HEAD names whatever init.defaultBranch was, which need
	## not be the branch just pushed. A clone of an origin whose HEAD names a
	## branch it does not have checks out nothing, and what follows would be
	## measuring that rather than anything cageworks does.
	git -C $ORIGIN symbolic-ref HEAD refs/heads/main" || {
	echo "FAIL could not make an origin on the machine"
	exit 1
}

## 1. The clone reaches the machine's own pool, from a remote.
sshm "cageworks-container role-worktree $F $R $ORIGIN" >/dev/null 2>&1
check "the factory clones its origin onto its own machine" present \
	"$(sshm "[ -d $CLONE ] && echo present || echo absent")"

check "the clone knows the remote it came from" "$ORIGIN" \
	"$(sshm "git -C $CLONE remote get-url origin 2>/dev/null")"

## 2. A role gets a worktree of it, owned by the uid nixcage allocated rather
## than by the supervisor that made it. ADR-028 puts the agent's number on it,
## since the agent is what opens the repository.
agent_uid="$(sshm "nixcage-container uid $R agent" 2>/dev/null)"
check "a role's worktree exists" present \
	"$(sshm "[ -d /var/lib/nixcage/worktrees/$F/$R ] && echo present || echo absent")"
check "and belongs to the agent rather than to root" "$agent_uid" \
	"$(sshm "stat -c %u /var/lib/nixcage/worktrees/$F/$R 2>/dev/null")"

## 3. A session runs in a cage on that worktree and sees the repository. This
## is the sentence that was not true of any factory machine before now.
check "a session runs in the cage and sees the repository" present \
	"$(sshm "cageworks-container role-enter --repository $ORIGIN $F $R \
       sh -c 'test -f /workspace/README.md && echo present || echo absent' 2>/dev/null |
     tail -1")"

## 4. And it runs as the agent rather than as cage root. The number inside is
## the offset into the block and not the host's: nspawn maps container uid 0
## upward onto the range, so the agent is 1 in here and $agent_uid out there.
## Both are checked, because either alone would pass on a cage mapping nothing.
check "the session runs as the agent and not as cage root" 1 \
	"$(sshm "cageworks-container role-enter --repository $ORIGIN $F $R \
       sh -c 'id -u' 2>/dev/null | tail -1")"

check "and the agent is that block's second number on the machine" "$agent_uid" \
	"$(sshm "nixcage-container uid $R agent" 2>/dev/null)"

nix develop --command bash cageworks down "$F" >/dev/null 2>&1
exit "$fail"
