---
id: ADR-024
title: A take is a claim and a revalidation, and every git-bug call retries the repository lock
status: accepted
date: 2026-09-06
status_date: 2026-09-06
summary: winning the claim ref is not taking a task, and git-bug locks the whole repository for reads as well as writes
depends_on: [ADR-021, ADR-022]
supersedes: [ADR-023]
superseded_by: []
---

## Context

ADR-023 decided that an agent takes a task by creating `refs/claims/<task>`
with an expected old value of `""`, and that the claim is a lease. That
document was written against a model, and the model was run. Both the decision
and the model were wrong in the same place, and neither could see it, because
they shared an assumption.

A spike ran the decision instead of describing it: a real `pi --mode rpc`
channel, a real git-bug queue, real `update-ref`, and several loops racing one
repository. The loop shape held. Two things underneath it did not.

**A task was worked twice, and the compare-and-swap was working correctly when
it happened.** Reading the queue and swapping the claim are separate
operations, and the record can change between them. Agent B lists the takeable
tasks and sees `t`. Agent A takes `t`, works it, finishes it, and deletes its
claim on the way out. Agent B now runs its create-only swap against a ref that
is absent, so the swap succeeds. It succeeds *because* A released. The claim is
granted for work that is already done, and the guard that was supposed to
prevent exactly this is the reason it was granted.

ADR-023's model asserted this away. `claimCreate` carried the guard
`finishCount.get(t) == 0`, which is the claim that reading the queue and
swapping the ref happen as one atomic step. Everything downstream of that guard
was checked against a world where the race does not exist. The model was not
lying; it was answering a question narrower than the one that mattered, and the
document reported "no violation found" without noticing which question it was.

**And the record itself does not tolerate concurrency.** git-bug 0.10.1 takes an
exclusive lock on the whole repository for every operation, reads included, and
fails immediately rather than waiting. Five concurrent reads leave four dead.
Twenty-four concurrent bare operations leave three alive, failing in three
distinct classes:

```
  10 already locked by the process pid N
   9 strconv.Atoi: parsing "": invalid syntax
   2 remove .git/git-bug/lock: no such file or directory
```

The first is the lock working as designed. The second and third are the lock
failing: the unlock path removes the lock file without owning it, so one
process deletes another's lock and a third gets a parse error on the empty
file it finds. ADR-022 chose git-bug as the only task store on the strength of
it being a git-native record several agents share. It is that, but only one
process may touch it at a time.

The two findings compound. `modules/record.sh` reads the queue with
`2>/dev/null`, which turns a lock failure into an empty result, which the loop
reads as "no work" and exits. In the spike this starved a whole agent on every
run before it was fixed, and it is invisible: the loop reports going idle,
which is what a loop with nothing to do also reports.

## Decision

**1. Winning the claim is not taking the task. Revalidating is.** After the
compare-and-swap succeeds, and before any work begins, the holder re-reads the
task from the record and confirms it still carries the label for the capability
being taken. If it does not, the holder deletes the claim it just created and
goes back to reading. The swap decides who may consider the task; the
revalidation decides whether there is still a task to consider.

The revalidation must happen while holding the claim, not before it. Before the
claim it is another stale read, one window earlier. Holding the claim is what
makes the answer stable, because no peer can start on the task while the ref
exists.

**2. A refused revalidation deletes the claim immediately.** The claim is not
left to lapse. A claim held for work nobody is doing strands the task for a
whole lease, and the lease exists for holders that died, not for holders that
declined.

**3. Every git-bug invocation retries the repository lock.** No `git-bug` call
in cageworks runs bare. Each goes through one wrapper that retries on a locked
repository with jittered backoff up to a bounded number of attempts, and
returns the failure when the attempts run out. This is a work-around for
somebody else's defect and is written as one.

The wrapper retries all three failure classes above, not only the first. The
second and third are the lock's own race and are transient in exactly the way
the first is; treating only the honest one as retryable is how the spike lost
an agent after the wrapper was already in place.

**4. A lock failure is never read as an empty queue.** No git-bug call
discards its standard error, and a reader that fails returns non-zero rather
than nothing. An agent that cannot read the record has not learned that the
record is empty, and the two must not produce the same behaviour.

**5. The number of agents in a factory is bounded by one lock.** Every role
loop in a factory contends a single exclusive lock on a single repository, so
the concurrency a factory can declare is a property of git-bug and not of the
machine. The operator's `concurrency` ceiling is what expresses that today. If
it stops being enough, the fix is a record that does not serialise, which
supersedes ADR-022 rather than tuning this wrapper.

**6. What ADR-023 decided and this document keeps.** All of it, except the take.
A claim is a ref created by compare-and-swap; `refs/claims/` is writable by
every role; a claim is a lease and a renewal moves the ref; releasing and
stealing pass the claim's real value and never the all-zeros object id; the
clone uses the files ref backend; work no longer sticks to a role; a stage
names a capability; declaration order stops meaning anything. Those were
checked, and the finding that a renewal must move the ref still stands, and
came from the model rather than from reasoning.

## Consequences

A take costs one extra read of the record, on the path where the swap won. That
read is a git-bug call, so it also costs a turn on the repository lock, which
is the resource decision 5 says is scarce. It is paid once per task rather than
once per poll, and it is the difference between a task being worked once and a
task being worked twice.

The revalidation is presence of a label, and nothing else. It reads the same
metadata the queue read reads, so it stays inside ADR-022's rule that the
supervisor and the take are content-blind. A revalidation that judged whether
the work still needed doing would be reading prose, and would belong in a cage.

A claim can now exist for a task nobody is working, briefly, between the swap
and the revalidation refusing it. `holderMatchesRef` still holds, because the
ref and the holder move together, but "a claim exists" no longer implies "a
turn is running". Anything that reports on a factory has to say held rather
than working.

The retry wrapper makes contention slow instead of fatal, and hides how much
contention there is. A factory whose agents spend their turns waiting on the
record looks exactly like a factory whose agents have nothing to do. That is
worth a counter before it is worth a redesign, and neither is in this document.

The two failure classes the wrapper retries as transient are the lock's own
race, and treating a parse error as retryable is a bet that it is never a real
corruption. The bet is bounded: the wrapper gives up and returns the error, and
a store that is genuinely corrupt fails every attempt rather than a few. The
spike killed a git-bug process holding the lock and the store came back intact,
which is evidence for the bet and not a proof of it.

The Formal Modeling Gate fires, on the same shape ADR-023 named and on the seam
it missed: a claim handoff between processes in separate cages, with a
compare-and-swap, an expiry, and now a queue read that is not atomic with the
swap. `models/task-claim.qnt` is rewritten before the implementation, and the
rewrite is the point rather than the run: the read and the swap are separate
actions, nothing prevents a task from being finished between them, and
`claimCreate` carries no `finishCount` guard.

Five invariants hold, with no violation found over 30000 traces of up to 60
steps each: a claim ref exists exactly when somebody holds it, no role ever
holds work outside what it provides, a guarded delete never removes a claim
that had not expired, no task is ever finished twice, and nobody ever works a
task that is already done.

The fifth is new and is what decision 1 buys. It was checked for vacuity by
turning decision 1 off: with `revalidateAfterClaim` set to false, the model
reproduces the spike's double-work and the invariant fails. A guard that cannot
be broken is not being checked.

Four witnesses are stated as negations so that a violation is the evidence, and
all four violate: a task is worked by two agents at once when a hung holder
stops renewing, a crashed agent's task returns to the pool once its lease
lapses, a claim is granted for a task that is already finished, and that claim
is handed straight back. The third is the spike's finding made reachable in the
model; if it stopped violating, the model would have made the queue read atomic
again and the revalidation would be checked against nothing.

`models/factory-structure.als` does not change. What a role may write is
unchanged by this document, and the take is temporal rather than structural.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
quint run models/task-claim.qnt --invariant=allInvariants --max-steps=60
```

The lock behaviour is asserted against real git-bug rather than stubbed, since
it is the whole of decisions 3 and 4: concurrent writers through the wrapper
all land, the same writers bare do not, and a reader that cannot take the lock
returns non-zero rather than an empty queue. The three failure strings were
measured on git-bug 0.10.1 before this document was written.
