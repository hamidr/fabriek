---
id: ADR-028
title: A role's cage holds two subjects, and the loop is not one of them
status: proposed
date: 2026-09-08
status_date: 2026-09-08
summary: the loop enters as cage root and starts the agent as a subject, so what it records is not the agent's to rewrite
depends_on: [ADR-018, ADR-025, ADR-026, ADR-027]
supersedes: []
superseded_by: []
---

## Context

Two documents here record the same unpaid bill. ADR-026 says an agent with
`bash` can open its own console socket, steer itself, write the comment that is
supposed to record an operator, or kill the loop that counts its turns, and
that separating the two "would need the loop and the agent under different uids
in one cage, which the enter primitive cannot express, so it is an interface
change in nixcage before it is a change here". ADR-027 rests on the same fact
twice: its context says the loop and the agent are one uid, and its
consequences say a role can still forge its own ledger because an agent with
`bash` can write whatever it likes under its own uid.

nixcage's ADR-010 is that interface change. A principal is allocated a
contiguous block rather than one number, `nixcage.principalSubjects` declares
the subjects a cage has, `nixcage-container uid <principal> <subject>` answers
for one of them, and `enter --subject <name>` starts the command as that
subject instead of as cage root. Cage root keeps `CAP_SETUID` over its own
block and reaches nothing beyond it, which is why a supervisor enters as cage
root and starts what it supervises under a subject rather than dropping first.

One fact makes this urgent rather than merely available. A block is fixed when
it is allocated, and declaring a subject later does not widen a principal that
already exists: giving subjects to such a principal means a new principal and
chowning everything the old one owned. Every role allocated on a factory's
machine before this decision is a role that can never gain a subject in place.

## Decision

**1. A factory's machine declares one subject, and it is the agent.**
`nixcage.principalSubjects = [ "agent" ]`, so every role principal is allocated
a block of two: cage root at the base, the agent at the next number. One and
not more, because the only separation any document here has asked for is
between the thing that supervises and the thing that runs whatever code it is
asked to.

**2. The agent owns the worktree, the home and the signing key.** nixcage's
ADR-010 names this as the sharp edge: whichever subject owns the workspace
fixes which subject may run nix in it, and a session entered under a different
subject than the one owning the tree gets libgit2's owner error back. The agent
is what commits, so the agent is what owns. `storage ensure` is called with the
agent's number, the ACLs `role-worktree.sh` grants name the agent's number, and
`signing.sh` writes a key the agent can read.

**3. A role session enters as the agent.** `role-enter` asks for the agent's
uid, passes `--subject agent`, and names a home that is the agent's. This is
true today, before any loop exists, because what a role session runs today is
the agent. Cage root is a subject nothing enters as yet.

**4. The loop will enter as cage root and start the agent itself.** When
ADR-026 is built, the loop is the session and the agent is its child under
`--subject agent`. Recorded here rather than built, because there is no loop to
enter as anything.

**5. What the two other sources see is the agent's number, not the block's.**
ADR-027's journald stamps `_UID` off `SO_PEERCRED` and its kernel probes report
the uid that ran the exec, and both of those are the agent once point 3 holds.
ADR-025's packet filter denies a role by there being no rule naming it, so a
block changes nothing there: neither number is in the allowlist and neither
leaves the machine.

**6. Existing role principals are not migrated.** A role allocated with a block
of one keeps it and gets no agent subject. Nothing in this repository renames a
principal or chowns a worktree to repair one, because a rename is a new
principal and a new worktree and that is a person's decision about their own
factory rather than something a program should do to it on an upgrade. The
factories this reaches are the ones built after it.

## Consequences

**ADR-026's console weakness is repaired, and ADR-027's ledger consequence is
narrowed.** Once the loop is cage root and the agent is a subject, the agent
cannot signal the loop, open what the loop owns, or write an entry stamped with
the loop's uid. What survives is that the agent can still write entries stamped
with its own, which is the same distinction ADR-027 point 4 already draws
between an entry that lies about what it did and one that lies about who it is.
Both documents keep their text and are amended by this one.

**A role session is no longer root inside its own cage.** Anything that assumed
it could write outside its home without asking finds out here. The three paths
a role holds are named explicitly already -- the worktree, the home and the
task directory -- so the surface this touches is the one nixcage's ADR-010
names: a home that is not `/root`, and whatever resolves a profile from it.

**This is built on a proposed decision whose central property is unmeasured.**
nixcage's ADR-010 point 7 says cage root reaches a uid inside its block and
nothing outside it, and says plainly that this is reasoned from how user
namespaces work rather than measured. Everything above rests on it. It is
measured below rather than assumed, and if it does not hold then point 4 buys
nothing and this document is wrong rather than merely early.

**A factory costs twice the uids.** `principalUidRange` holds proportionally
fewer principals and nixcage's exhaustion error arrives sooner. The range is
declared and reserved, so widening it takes nothing from anybody.

## Measurement plan

The claim the rest rests on, checked on a factory's own machine rather than
read out of a header file. `tests/manual/observe.sh` already enters a role
session and reads back the uid journald stamped on it; this adds the block.

```bash
# The block, and which number each subject answers with.
tests/manual/observe.sh subjects
# reports the principal's base, the agent's number, and whether they differ by one

# nixcage ADR-010 point 7, from inside a cage.
tests/manual/observe.sh containment
# cage root reaches the agent's uid and fails to reach the number after the block
```

The attribution pass already run for ADR-027 is what says the two other sources
agree, and after this it agrees on the agent's number rather than the block's
base. A run where journald stamps the base is a run where point 3 did not take
effect.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
nix develop --command bats tests/command/seam.bats
docmeta-check docs && docmeta-tracker --check docs
CAGEWORKS_PROOF_DIR=/tmp/proof tests/manual/observe.sh subjects
CAGEWORKS_PROOF_DIR=/tmp/proof tests/manual/observe.sh containment
```

`seam.bats` is named on its own because point 3 changes the argv a role session
composes in three places at once: the uid asked for, the `--subject` flag, and
the home. That file asserts the whole line, and that diff is its purpose.
