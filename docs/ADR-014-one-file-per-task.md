---
id: ADR-014
title: A task's mutable fields live in one file, written by rename
status: implemented
date: 2026-09-03
status_date: 2026-09-03
summary: every mutable field of a task is written together in one file, so a change cannot half-happen without a database
depends_on: [ADR-011]
supersedes: []
superseded_by: []
---

## Context

The factory's state was a directory per task with a file per field, and it had
a real defect. `nixcage_task_attempt` writes `attempts` and then `state` as two
renames, so a crash between them leaves a task with an attempt spent and its
state still `ready` -- a state the design forbids and the code can produce. Id
allocation was a `mkdir` mutex written by hand, retried with a timeout.

ADR-012 proposed moving the whole store to SQLite, and its strongest argument
was that a transaction makes that defect unrepresentable. Two of its four
arguments have since weakened. ADR-013 moved discussion into git-bug, which
removed the expensive read -- building a brief with its thread is no longer a
join here -- and left the store small: task rows, run records, the role-to-uid
map, and markers saying what each role has seen.

What did not weaken is the defect, and there is a way to fix it that was not
considered when ADR-012 was written. The two writes are only two writes because
the fields are two files.

## Decision

Every mutable field of a task lives in one file, and a change writes the whole
file through a temporary and a rename.

**1. One file, one rename.** State, attempts, stage, parent, outcome and the
rest are written together. A change either lands or does not; there is no
window where half of it is visible, and no ordering anyone has to remember.

**2. Ids are allocated by `mkdir`.** Creating a task's directory either
succeeds or fails, which is the atomic test-and-set the previous lock was
wrapped around. The lock goes, and with it the retry loop and its timeout.

**3. Text stays in its own file; the file that changes holds scalars.** The
shared file is line-oriented, so a value containing newlines cannot live in it
without an encoding, and the values that do -- acceptance criteria, a task
body, an outcome a role wrote, a failure reason -- are each written once and
never paired with anything. Only scalars share the file: state, attempts,
stage, role, workflow, parent and the sequence number.

That is enough, because the pairing that matters is scalar. The forbidden
outcome is an attempt counted without the state change that goes with it, and
both are scalars in the one file. An outcome written just before a state change
that does not land leaves a task still running with an outcome the next attempt
overwrites, which is untidy and not a state the design forbids.

**4. The store stays the supervisor's.** No cage reaches it, and the record
roles write into is git-bug (ADR-013). Task state governs dispatch, and putting
it where agents write would let a role mark its own task ready and start
itself.

**5. Validation stays in shell.** The eight task states and the relations
between tasks are checked by the code that writes them, not by a schema.

## Consequences

The defect becomes unrepresentable, which was the point, and it costs a schema,
a migration path and a dependency less than the alternative did.

Validation is not enforcement. A `CHECK` constraint would refuse a ninth state
whatever wrote it; a shell function only refuses what goes through it. Nothing
else writes this store today, and if anything ever does, that is the argument
for revisiting.

The state stays readable with `cat`, which is not nothing: every defect found
in the VM today was found by looking at files, including the stale home whose
`.cache` belonged to another uid.

Reads are still directory walks. Listing the ready tasks of a factory opens one
file per task rather than several, which is better than it was and no better
than an index. The store is small enough that this does not matter yet, and
read markers are the first thing likely to make it matter.

SQLite remains the answer if this store grows relations. That is a judgement
about size rather than taste, and ADR-012 records the reasoning should it be
needed again.

## Verification

The existing tests describe behaviour rather than storage -- a task starts
proposed, ids are never reissued, listing is oldest first, a value with quotes
and tabs round-trips, twenty four concurrent filings produce twenty four
distinct ids -- and are expected to pass unaltered. That is what they were
written for.

One property becomes testable that was not expressible before: a reader never
sees a torn write. Note that a spent attempt with a `ready` state is not itself
the defect -- that is exactly what a failed attempt leaves behind, and it is
legal. The defect is a reader seeing one field from a write and another field
from the write before it. The test writes two scalars that must always be
equal, hammers them concurrently, and asserts no reader ever observes them
differing.

Measured on the VM's own filesystem rather than the developer's machine, since
that is where the rename and the directory allocation actually run.
