---
name: discipline-review
description: Review a branch for test-first evidence, domain placement, single responsibility and a pure core, and block with one finding per line when it fails. Use on every review before the verdict.
---

# Reviewing for discipline

Run after reading the diff and running the tests. Each check is a
question with a yes or no; a no is a finding.

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
