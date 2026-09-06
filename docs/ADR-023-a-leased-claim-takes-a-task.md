---
id: ADR-023
title: A task is taken by a leased claim on a ref
status: proposed
date: 2026-09-06
status_date: 2026-09-06
summary: capable agents race to create a claim ref, git's ref lock decides the winner, and the claim is a lease that expires
depends_on: [ADR-010, ADR-021, ADR-022]
supersedes: [ADR-015]
superseded_by: []
---

## Context

ADR-015 resolves who works a task by walking the declared roles and picking the
first idle capable one. That works because one uncaged program does the walking
and nobody else is looking. ADR-021 removes it: several agents poll the same
record at the same time, each sees the same takeable task, and each is capable
of it. Without something atomic between them, two agents work one task, on two
branches, and the second discovers it when the first has already finished.

The state they share is a git repository and nothing else. There is no lock
server, no database and no uncaged arbiter left to be one, so the atomic thing
has to be something git already does atomically.

Git already does it. Creating a ref takes a lock in the ref's own parent
directory, and `update-ref` accepts an expected old value, with the empty string
meaning the ref must not exist. On git 2.55.0 the second of two such creates
fails with `cannot lock ref: reference already exists` and exit 128, and a
delete whose expected value does not match fails with `is at X but expected Y`
and exit 1. That is a compare-and-swap, provided by the thing every role already
has write access to a corner of.

## Decision

**1. A claim is a ref, created by compare-and-swap.** An agent takes a task by
running `git update-ref refs/claims/<task> <claim> ""`, where the empty expected
value means the ref must not already exist. Success is the take. Failure means
somebody else took it, and the agent goes back to reading the record. There is
no retry loop and no backoff, because the loser has nothing to wait for.

**2. `refs/claims/` is writable by every role.** A POSIX ACL grants each
allocated role uid `rwX` on that directory and its reflog directory, as ADR-010
point 5 does for a role's own branches and ADR-022 does for `refs/bugs/`. This
is what makes the compare-and-swap shared, and it means a role can also delete a
peer's claim. The mechanism stops two agents from racing; it does not stop one
from misbehaving.

**3. A claim is a lease.** It carries a deadline, and the holder renews it while
it works. An expired claim may be taken by any capable agent, so an agent that
crashes, a machine that is stopped and a laptop that is closed do not strand
work. A lease that is never renewed is indistinguishable from a dead holder,
which is the point.

**4. Releasing and stealing pass the claim's real value.** `update-ref -d`
against a mismatched expected value refuses, which is what makes a steal safe:
an agent reclaiming an expired lease deletes the exact value it read. The
all-zeros object id must never be used for this. Git reads it as "the ref does
not exist" and the delete succeeds against a live claim, which was found by
testing and is the one way to get this wrong silently.

**5. The clone uses the files ref backend.** All of the above is the behaviour
of loose refs in a directory an ACL can name. A reftable clone has no such
directory, and packing can move a claim into `packed-refs`, which no role may
write. The factory's clone is created with the files backend and its claims are
kept out of packing.

**6. Work no longer sticks to a role.** ADR-015 had a task stay with whoever
took it, because its branch lived in that role's namespace and no peer could
write it. A lease that any capable agent may reclaim ends that. An agent taking
over an expired claim starts a fresh branch in its own namespace, from the
commit the previous holder reached, which it can read because the object
database is shared even though the branch is not writable. Continuity of work is
preserved; continuity of worker is not.

**7. What ADR-015 decided and this document keeps.** A stage names a capability
rather than a role, and roles declare what they provide, so capacity at a stage
is added by declaring another role instead of editing the pipeline. Each stage
states its own `ready`, the fields a task must carry before the stage will take
it, checked for presence and nothing else. Each stage states its own `done`,
which is prose handed to the role and never checked, because judging whether
work meets a bar is reading content and belongs in a cage.

**8. Declaration order stops meaning anything.** ADR-015 resolved ties by it.
The winner is now whichever agent's poll and compare-and-swap landed first, and
the order roles appear in is a fact about a file.

## Consequences

Which agent works a task becomes non-deterministic. Two runs of the same factory
on the same record can assign differently, and reproducing a scheduling
complaint means reproducing a race. Nothing downstream depends on the assignment
being predictable, and the alternative was keeping an arbiter outside the cages,
which ADR-021 removed for reasons that still apply.

The lease has to be renewed by something that is not the turn. If an agent's
turn is one long invocation, that invocation cannot tick its own deadline, so
the cage runs a renewer beside it and the renewer stopping is what expires the
claim. Getting this wrong in the safe direction means a peer steals work that is
still being done, which is the failure this document most has to avoid, and the
model below is where that is checked rather than argued about.

Claims accumulate. A finished task's claim is deleted by its holder, and one
whose holder never came back is deleted by whoever reclaims it, so nothing
prunes a claim for a task that was cancelled while held. That is a sweep the
supervisor can do, and it is the only piece of taking that stays outside the
cages.

The Formal Modeling Gate fires, on exactly the shape it names: a lease handoff
between processes in separate cages, with a compare-and-swap and an expiry.
`models/task-claim.qnt` is written and run before the implementation, over
several capable agents, one record and a clock that may expire a lease at any
point including during a turn. Two invariants: no two agents ever hold one task,
and no takeable task stays unclaimed forever.

`models/factory-structure.als` changes in the same commit, because what a role
may write changes. Its ref model has a role writing only its own namespace, and
`refs/bugs/` and `refs/claims/` are now writable by all of them, which is what
its assertions about ref partition have to be told.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
alloy6 exec models/factory-structure.als
quint run models/task-claim.qnt --invariant=allInvariants --max-steps=60
```

The compare-and-swap is asserted against real git rather than stubbed, since it
is the whole decision: two processes creating one claim ref leave one at exit 0
and one at exit 128, a delete with a mismatched expected value leaves the ref in
place at exit 1, and a delete with the all-zeros object id is refused by
cageworks before it reaches git.
