#!/usr/bin/env bash
## PRD-004 phase 2's exit condition, which needs a real machine and so cannot
## be a bats test.
##
## A factory's machine is stopped and started ten times while its pool holds
## work, and every file is checked against a manifest each time. ADR-017 exists
## because a VM was ended rather than shut down and worktrees came back empty;
## fabriek owns the stopping now, so this is the evidence rather than the
## argument.
##
## Wants a scratch directory holding an operator config and a repository that
## declares a factory called acme:
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   tests/manual/stop-and-start.sh
##
## Prints down, up and boot seconds per cycle, which is also where ADR-019's
## measurement of what a machine costs comes from.
##
## The record is checked alongside the work, because ADR-036 puts the forge's
## data on the same pool and a board that does not come back is one nobody
## can rely on after the first restart.
set -uo pipefail
cd "${FABRIEK_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 1
S="${FABRIEK_PROOF_DIR:?set FABRIEK_PROOF_DIR to a scratch directory}"
export FABRIEK_MACHINES="$S/machines" FABRIEK_CONFIG="$S/cfg.toml" \
       FABRIEK_LIB="$PWD/modules" FABRIEK_SELF="$PWD"
D="$S/machines/acme"
sshm() {
  ssh -i "$D/id_ed25519" -p "$(cat "$D/port")" -o UserKnownHostsFile="$D/known_hosts" \
    -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o BatchMode=yes \
    -o ConnectTimeout=3 root@localhost "$@"
}
wait_ssh() { for i in $(seq 1 120); do sshm true 2>/dev/null && { echo "$i"; return 0; }; sleep 1; done; echo timeout; return 1; }

echo "initial boot wait: $(wait_ssh)s"

# Work in flight: 300 files on the pool, and a manifest of what they were.
# shellcheck disable=SC2016  # runs in the machine, expands there
sshm 'set -e; rm -rf /var/lib/nixcage/proof; mkdir -p /var/lib/nixcage/proof
  for i in $(seq 1 300); do head -c 20000 /dev/urandom > /var/lib/nixcage/proof/f$i; done
  cd /var/lib/nixcage/proof && sha256sum f* > /var/lib/nixcage/manifest.sha256
  wc -l < /var/lib/nixcage/manifest.sha256' || exit 1

# One issue on the record, opened before the first stop. It is opened through
# the forge rather than written into a file, because what is being checked is
# that the board came back and not that a file did (roadmap 2.5).
# shellcheck disable=SC2016  # runs in the machine, expands there
sshm 'set -e
  mountpoint -q /var/lib/nixcage/forgejo
  t="$(cat /var/lib/nixcage/forge/operator-token)"
  curl -sf -X POST -H "Authorization: token $t" -H "Content-Type: application/json" \
    -d "{\"title\":\"stop-and-start proof issue\"}" \
    http://10.77.0.1:3000/api/v1/repos/operator/acme/issues >/dev/null
  echo opened' || exit 1

for cycle in $(seq 1 10); do
  t0=$(date +%s)
  nix develop --command bash fabriek down acme >/dev/null 2>&1 || { echo "cycle $cycle: down FAILED"; exit 1; }
  t1=$(date +%s)
  nix develop --command bash fabriek up acme >/dev/null 2>&1 || { echo "cycle $cycle: up FAILED"; exit 1; }
  t2=$(date +%s)
  boot=$(wait_ssh)
  if ! sshm 'cd /var/lib/nixcage/proof && sha256sum -c --quiet /var/lib/nixcage/manifest.sha256' 2>&1; then
    echo "cycle $cycle: MANIFEST MISMATCH"; exit 1
  fi
  empty=$(sshm 'find /var/lib/nixcage/proof -type f -size 0 | wc -l')
  # The record is on the pool too, so it is part of what a stop has to survive.
  if ! sshm 'mountpoint -q /var/lib/nixcage/forgejo' 2>/dev/null; then
    echo "cycle $cycle: THE RECORD IS NOT ON THE POOL"; exit 1
  fi
  # shellcheck disable=SC2016  # runs in the machine, expands there
  record=$(sshm 'for _ in $(seq 1 60); do curl -sf http://10.77.0.1:3000/api/v1/version >/dev/null && break; sleep 1; done
    curl -sf -H "Authorization: token $(cat /var/lib/nixcage/forge/operator-token)" \
      "http://10.77.0.1:3000/api/v1/repos/operator/acme/issues?state=all&type=issues" | grep -c "stop-and-start proof issue"')
  if [ "${record:-0}" -lt 1 ]; then
    echo "cycle $cycle: THE RECORD DID NOT COME BACK"; exit 1
  fi
  echo "cycle $cycle: down=$((t1-t0))s up=$((t2-t1))s boot=${boot}s intact empty=$empty record=$record"
done
echo "ALL TEN CYCLES INTACT"
