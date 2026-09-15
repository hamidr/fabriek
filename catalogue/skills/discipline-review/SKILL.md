---
name: discipline-review
description: Review a branch for test-first evidence, domain placement, single responsibility and a pure core, and block with one finding per line when it fails. Use on every review before the verdict.
---

# Reviewing for discipline

Run after reading the diff and running the tests. Each check is a
question with a yes or no; a no is a finding.

## Read-only, and one reviewer

The builder's branch is in your worktree to read. Do not move HEAD,
the index or any ref on it; `git show`, `git diff` and `git log` answer
everything, and a second checkout of a revision goes in a directory
under your home. The whole review is yours in one pass; a diff too
large for one pass is reviewed in several by you and the outcome says
so.

## Against the task

Before discipline, the task:

- Does the change do what the task asked, all of it, and nothing the
  task did not ask? A deviation is named as one: an improvement the
  builder chose, or a departure; the outcome says which and lets the
  next stage decide.
- Where the task cites a record, does the change follow it? A change
  that departs from a recorded decision is a finding whoever is right;
  the record is changed by the architect, not by a diff.
- Errors: what happens on the bad input, the missing file, the closed
  socket, at every edge the change adds. A path with no handling and no
  test is a finding.
- Tests: do they exercise the real thing, or a fake standing where the
  real thing would have failed? Are the edges the task named covered?
  Do they all pass when you run them, not when the thread says so?
- Compatibility: a schema, a file format or an interface changed
  without the migration or the reader on the other side is a finding.

## Test first

```sh
git log --reverse --name-only --format='%h %s' main..HEAD
```

For each commit that touches production code: does the same commit, or
an earlier one, add or change a test that covers it? A production change
with no test in its commit or before it is a finding: `no test precedes
<file>`.

Run the suite. Delete one new production line in your worktree and run
the tests that claim to cover it; if nothing fails, the test is vacuous.
Restore the line. One such probe per task is enough to say whether the
tests bite.

## Domain

- Every new name is a glossary term, spelled as the glossary spells it.
- A rule sits on the entity or aggregate that owns the data it checks.
- No import crosses a bounded context outside a seam the overview draws.

## Shape

- Each new unit has one reason to change; a Manager, Helper or Utils
  name, or fields only some methods touch, is a finding.
- A dependency crosses an interface the caller owns; a concrete adapter
  imported into the domain is a finding.
- A third copy of a shape without a shared unit is a finding; a shared
  unit for two copies is also one.

## Purity

- Data mutated in place where a new value would do.
- I/O, time or randomness inside a function that also decides.
- Errors thrown across a seam where a value would carry them.

## The verdict

One line per finding: `path:line: what is wrong; what would fix it`.
Ordered by severity; stop at what matters. Any finding under Test first
blocks. Findings under the other three block when they touch the domain
and are noted when they touch glue. No praise, no restating the diff.
