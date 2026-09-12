---
id: ADR-033
title: A cage is an actor, and the executor is the one sender of work
status: proposed
date: 2026-09-12
status_date: 2026-09-12
summary: actors announce ready on a bus and are sent work by one uncaged sender, so mutual exclusion is a property of the sender
depends_on: [ADR-015, ADR-018, ADR-019]
supersedes: [ADR-024]
superseded_by: []
---

## Context

ADR-023 and ADR-024 let every role take its own work by a leased claim on a
git ref. What that bought was a factory without a dispatcher; what it cost
was a distributed mutual-exclusion protocol resolved read-side, git-bug's
repository lock shared by every writer, and a model that once reported no
violation because it shared the decision's own assumption about atomicity.

The threat model was restated before any of this was re-derived: an agent
may try to escape, exfiltrate and forge. Every mechanism that only works if
the agent cooperates goes. A self-taken claim is one of those, because the
claim is written by the party it constrains.

Nothing here has to be a race. The machine is ours (ADR-019), and one process
on it can be the only thing that ever sends work.

## Decision

**1. Each cage is an actor.** It announces `ready` with the capabilities its
role provides, receives an assignment pointer, works, comments its outcome
on the issue, and announces `ready` again. It takes nothing.

**2. Valkey is the bus, and it is control plane only.** One mailbox stream
per actor, one `findings:<role>` stream per role, a `probes` stream for the
machine. No persistence: state that matters is on the board (ADR-036).
Valkey rather than Redis for the licence reason ADR-029 already made.

**3. A Valkey ACL user per role,** default-deny (`resetkeys resetchannels
nocommands`, then the stream verbs it needs), its password made per role at
`cageworks up` and set at boot, so rotation is a restart and no bus secret
exists at rest. A findings stream is writable by the role it is named for
alone, so attribution is the ACL's rather than the message's.

**4. Delivery records intent, sends, and confirms on the ack.** The executor
writes `assigning` to the board before it sends; the actor's ack moves the
row to `assigned`. On startup the executor reconciles before routing: it
asks every live actor what it holds and uses the answers only to resolve
`assigning` rows. An answer never creates an assignment, because under the
threat model an answer is a claim. An actor that does not answer within a
timeout is unknown rather than free, and its tasks stay unrouted.

**5. An actor that cannot finish blocks in place.** It keeps its task and
its worktree, comments that it is blocked, and never announces `ready`; the
executor labels the issue. Capacity at a capability is added by declaring
another role (ADR-015 point 2). PRD-003's clause that a waiting run holds no
concurrency is withdrawn.

**6. A role's uid, home and signing key are permanent; its worktree is per
task,** an ordinary directory created and destroyed inside the role's one
quota'd dataset. Discarding the workspace is the rollback ADR-017 point 5
refused, and its objection does not apply when the operation is destroy.

**7. Peers broadcast findings and route work.** A role may write its own
findings stream and read every other's. Work always passes the executor.

## Consequences

The whole take protocol is deleted: no claim refs, no lease, no renewal, no
read-side resolution rule, no sweeper, no `ZPOPMIN`, no files-ref backend
requirement, and `models/task-claim.qnt` with them. Mutual exclusion is a
property of there being one sender. PRD-003's structural property returns:
no run is ever started by a cage.

A hung-but-alive actor holds its task forever, which a lease would also have
missed. A blocked role is spent capacity, and the operator needs a view of
who is blocked on whom, because a task blocked forever is a role gone
forever. A bus with no persistence means an actor must re-announce `ready`
after a Valkey restart, and the executor treats it as unknown until it does.

The dispatcher PRD-005 refused to build is back, and ADR-034 makes it smart
on purpose.

## Verification

Executor scenarios (docs/roadmap.md 3.3): an actor that crashes between
send and ack, one that stalls, and one that answers reconciliation with a
task it was never sent; in every case no task is `assigned` to two actors
and no `assigned` row exists that the executor did not send. A bats test
enumerates `ACL DRYRUN` per user against `EVAL`, `CONFIG`, `ACL` and `SCAN`
and expects every one refused.
