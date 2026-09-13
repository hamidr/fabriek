---
id: ADR-022
title: The task is a git-bug issue and nothing else
status: superseded
date: 2026-09-06
status_date: 2026-09-12
summary: tasks move into git-bug with their state as labels, every role writes the record itself, and the file store is deleted
depends_on: [ADR-011, ADR-021]
supersedes: [ADR-013, ADR-014]
superseded_by: [ADR-036]
---

## Context

A task's state and a task's discussion live in two places today. ADR-013 put the
record in git-bug inside the repository and then kept task state out of it: its
point 8 says git-bug knows open and closed, and the eight states, the stages,
the attempts and the caps stay in the supervisor's own store, which ADR-014
holds as files written by rename. Two stores, two consistency stories, and a
join between them that only the supervisor can perform.

ADR-021 makes that arrangement unworkable rather than merely untidy. The store a
task lives in is now read and written from inside cages, by several agents at
once. ADR-014's store is neither reachable that way nor safe that way: it is one
directory owned by the supervisor, made atomic by `rename(2)` under a single
writer, and its guarantee is exactly the one that lapses when there are several.
ADR-013's point 2 has the same problem from the other side. It makes the
supervisor the only writer because git-bug keeps the acting identity in a
repository-local config key, so one clone means one identity at a time. Roles
that write their own record entries need that to stop being true.

## Decision

**1. A task is a git-bug issue.** There is no second store. The title, the body,
the discussion, the state, the stage, the workflow and the fields a stage
requires are all attributes of one entity under `refs/bugs/`, and the record and
the work travel together in the repository, which was ADR-013's goal taken the
rest of the way.

**2. State and fields are labels.** Written with a dash and never a colon,
because a colon breaks git-bug's own query parser, which is why mentions are
already `needs-<role>`. Listing by label is how an agent finds what it may take,
and it stays metadata in and metadata out.

**3. Every role writes the record itself.** A POSIX ACL grants each allocated
role uid `rwX` on `refs/bugs/` and its reflog directory, the same mechanism
ADR-010 point 5 uses for a role's own branches. The supervisor stops being the
writer, and stops narrating: an agent records its own turn, as itself.

**4. A role's identity is per worktree.** `extensions.worktreeConfig` is set on
the factory's clone and each role's `git-bug.identity` is written with `git
config --worktree`, so the identity is a property of the worktree the agent
works in rather than of the clone they share. This is what makes point 3
possible and it was tested rather than assumed.

**5. ADR-014's store is deleted.** The task directory, the one file per task and
the write-by-rename go, together with the code and the tests that keep them.
Atomicity comes from git's ref lock now, which ADR-023 relies on for taking a
task and which is the same guarantee at a different layer.

**6. What ADR-013 decided and this document keeps.** Issues and comments are git
objects under `refs/bugs/`, so there is no shared database anywhere. Syncing is
`git-bug pull` and `git-bug push` and never a bare refspec, because entities are
operation logs that merge and a plain ref move silently discards one side; that
was measured. Bodies reach git-bug on standard input and never on a command
line. Mentions are labels rather than prose, because parsing a mention out of a
body would mean reading agent-authored text. Each role has a git-bug identity of
its own, so every entry is attributed to whoever wrote it.

## Consequences

Any role can write an entry attributed to another. The ACL of point 3 grants
write to a ref namespace, not to one identity's entries within it, and git-bug's
identity is a config value the writer sets. The record stops being evidence of
who did what against a hostile role, and remains an accurate account of a
factory whose agents are not trying to lie. Nothing in the design depended on
the stronger property; the supervisor never used the record to decide anything.

Two agents commenting on one task write one entity's ref and one of them loses
the lock and retries. Different tasks are different refs and never contend.
git-bug's operation logs merge, so a retry is a retry and not a lost write, but
an agent that treats a failed write as a failed turn will do the turn twice.

The supervisor's narration ends. ADR-013 point 7 had each transition appended as
a comment, so an issue read top to bottom was the story of the work. That story
is now written by the agents themselves, and it is only as good as they are.

Migration is a rewrite, not a conversion. Every task in an existing factory's
file store is either recreated as an issue by hand or abandoned. There is no
importer, because the states, stages and attempts a file carries are exactly
what the labels of point 2 have to be designed to hold, and writing an importer
before that design has settled would fix it prematurely.

The Formal Modeling Gate does not fire on this document in the sense of needing
a model of its own. Moving where a task is stored changes no behaviour over
time: the same states, the same stages, the same lifecycle. It fires on taking
one, which is ADR-023.

What does change is structural, and it lands in `models/factory-structure.als`
alongside ADR-023's half of the same widening. That model has each role writing
only its own namespace, and point 3 makes the record writable by all of them,
so its ref partition has to be told where the partition now stops.

## Verification

```bash
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
```

`tests/unit/task_store.bats` is replaced rather than adapted, and the suite
drives git-bug for real as it does today: a task carries its state as a label
and is found by it, two roles writing different tasks both succeed, two roles
writing one task both land after a retry, and a role's entry is attributed to
that role's identity while another role works the same clone.
