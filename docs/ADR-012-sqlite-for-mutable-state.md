---
id: ADR-012
title: A factory's mutable state lives in SQLite; the declaration stays files
status: proposed
date: 2026-09-03
status_date: 2026-09-03
summary: tasks, runs and uid allocations move into SQLite, while the Nix-rendered declaration stays a directory tree
depends_on: [ADR-011]
supersedes: []
superseded_by: []
---

## Context

Everything nixcage reads and writes is currently a directory tree with one file
per value. That began with the declaration the platform module renders, where
the reasoning is sound: Nix renders files and cannot render a database without
a build step, the declaration is read-only, it is replaced wholesale on every
generation, and a shell script reads a value by reading a file with no parser
and no client library between them.

The same shape was then used for state that is none of those things. Tasks,
run records and the role-to-uid map are mutable, written concurrently, related
to one another, and read together. The argument that
carried the declaration was reused without being re-examined, and it does not
carry here.

Three things say so, and the first is not a preference.

`nixcage_task_attempt` writes `attempts` and then `state` as two separate
renames. A crash between them leaves a task with an attempt spent and its state
still `ready`, which is a state the design does not allow and the code can
nonetheless produce. That is a latent defect already committed, and no amount
of care in shell removes it: two files cannot be written atomically.

Id allocation is a hand-rolled `mkdir` mutex, retried in a loop with a
timeout. It works, and it is a mutex written by hand around a problem every
database solves.

Reads are file walks. Listing the ready tasks of a factory opens every task
directory and reads a file from each, which is a query written by hand over a
tree that has no index.

There is a fourth, quieter argument. The Alloy model checks that no task is
owned by an undeclared role, that a task sits at a stage its workflow declares,
and that states come from a closed set. In a schema those are a foreign key, a
join and a `CHECK`. The model and the store would then say the same thing in
two places rather than the model saying it alone.

## Decision

A factory's mutable state lives in one SQLite database; the declaration stays a
directory tree.

**1. What moves.** Tasks, run records, the role-to-uid allocation, and the
markers saying what each role has already seen. These are written, related, and
read together.

Discussion is not among them. ADR-013 puts issues and comments in git-bug,
which carries attribution, identity and merge, so this store holds the
supervisor's mechanics rather than the shared record. That removes one of the
arguments made below -- building a brief with its thread is no longer a join
here -- and leaves the others untouched. The one that decides it, that taking
an attempt must be atomic, is unaffected.

**2. What does not.** Everything under `/etc/nixcage`, which the platform
module renders from Nix: the factory declaration, role commands, workflow
stages and the consult graph. It is read-only, regenerated wholesale, and
rendering it into a database would mean a build step that produces one.

**3. One database per machine**, in nixcage's own state directory beside the
factory clones, in WAL mode so concurrent writers do not serialise behind a
lock of ours.

**4. Constraints carry the invariants that fit.** The eight task states are a
`CHECK`, `parent` is a foreign key to another task, a task's workflow and stage
are recorded rather than inferred, and ids are a primary key rather than a
counter file guarded by a mutex.

**5. Transactions where two facts change together.** Taking an attempt writes
the count and the state in one transaction. Advancing writes the parent's
terminal state and the child's creation in one. Neither can half-happen.

**6. The guest reads and writes it through the `sqlite3` command**, added to
the container script's runtime inputs. No cage ever reaches the database: a
role still receives a brief and writes an outcome as files, and the supervisor
is the only thing that touches state, exactly as before.

## Consequences

The inconsistency described above becomes unrepresentable rather than
documented. That alone justifies the change; the rest is why it is not merely
tolerable.

There is now a schema, and therefore migrations. A directory tree tolerates a
new field by writing one; a database does not. The schema carries a version
from the first commit, and a nixcage that finds an older one migrates it or
refuses, rather than reading it wrongly.

State stops being inspectable with `ls` and `cat`, which genuinely helped while
debugging in the VM. It becomes inspectable with `sqlite3`, which is a fair
trade and not a free one.

DuckDB was considered and rejected for this, correctly. It is columnar and
analytical, and this is many small transactional writes. It remains the right
tool for the reporting PRD-003 asks for -- the share of `main` arriving on role
branches, interventions per merged task, revert rate, budget per merged task --
read over the record rather than owning it.

`sqlite-vec` is packaged and is not adopted here. Searching outcomes and the
record by meaning is plausible later, and choosing SQLite keeps that possible
while choosing files would have closed it. Nothing is built for it now, and no
embedding model is introduced.

The change is cheapest now. The store is roughly two hundred lines and thirty
four tests, and phase 2 of PRD-003 landed hours ago with nothing depending on
its internals beyond the guest script.

## Verification

The tests that exist describe behaviour rather than storage: a task starts
proposed, ids are never reissued, listing is oldest first, a field with quotes
and tabs round-trips, twenty four concurrent filings produce twenty four
distinct ids. They are the specification of this change and are expected to
pass unaltered against the new store, which is the point of having written them
that way.

Two new properties need their own tests, because they were not previously
expressible: taking an attempt is atomic, so a task is never found with a spent
attempt and a `ready` state; and a state outside the declared eight is refused
by the store rather than by a shell function that could be bypassed.

The migration path needs one: a database written by an older schema version is
migrated or refused, never read as though it were current.

Measured before this is called done: the concurrency test on the VM's own
filesystem, which is where WAL behaviour actually matters, rather than on the
developer's machine.
