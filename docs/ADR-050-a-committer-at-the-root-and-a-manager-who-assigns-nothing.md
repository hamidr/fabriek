---
id: ADR-050
title: The specialist tree is rooted in a committer, and a manager tunes the workflow without assigning
status: implemented
date: 2026-09-15
status_date: 2026-09-15
summary: committer is the root every specialist extends, developer the builder, manager owns policy, guidance, catalogue
depends_on: [ADR-031, ADR-034, ADR-040, ADR-042, ADR-049]
supersedes: []
superseded_by: []
---

## Context

ADR-042 made `developer` the base every specialist extends. Its tools
are all reading tools (`rg`, `fd`, `jq`, `python3`, and since ADR-049
`codegraph`), but its prompt is a builder's: test first, domain
placement, prove it before done. `architect` ("you do not write the
code") and `reviewer` ("you do not edit it") extend it, so both carry
"Test first. Every behaviour you add or change starts as a test" in
their `APPEND_SYSTEM.md`, two voices in one prompt. What those two share
with a builder is not building: it is working in a worktree of a
repository they did not write, reading before writing, keeping a change
the size of the task, and committing one logical change at a time. The
access itself is nobody's to give: every role has a worktree, a signing
key, a refs namespace and a forge account from the machine (ADR-010,
ADR-033), and `role-guidance.md` tells every session how git works in a
cage.

The architect's prompt also carried "split it into tasks a builder can
take": a responsibility with no mechanism. A role speaks through its
outcome, its comments and `mentions`; the decider alone speaks `file`
and `assign` (ADR-034 point 3), and reads outcomes, not threads
(`core.ts`, `lastOutcome`). Nobody owned the levers a factory has for
changing how it works: the decider's policy file (ADR-034 point 5),
`docs/factory-guidance.md`, and the repository's own catalogue (ADR-042
point 3).

## Decision

**1. `committer` is the root.** The tools that were `developer`'s, the
`tool-missing` skill, and the paragraphs that hold for anyone in a
worktree: one task in a repository you did not write; read before you
write, codegraph first; the change the size of the task; one logical
change per commit, imperative subject, body why; stop and say why when
you cannot continue; python3 when a shell line gets awkward. Nothing
about tests.

**2. `developer` is the builder.** Extends `committer`; keeps `tdd`,
`ddd`, `solid-fp` and the three building paragraphs (test first, where a
change belongs, prove it before done) plus the language-server paragraph,
since servers are declared by the builders' specialists. Every language
specialist still extends `developer` and its kit is unchanged; its
`APPEND_SYSTEM.md` gains one heading, `## committer`, in front.

**3. `architect` and `reviewer` extend `committer`.** The architect's
splitting paragraph is replaced: splitting is the manager's, done from
the architect's record, and a record that leaves a builder a decision to
make is not finished. An answer to a question is a record or a glossary
entry, not a comment.

**4. `manager` is new and assigns nothing.** Extends `committer` with
one skill, `workflow-tuning`. It owns three things and says which it
changed and why: the decider's policy (the file `decider.policy` names,
built into the machine at the pinned commit, ADR-040), the factory's
guidance (`docs/factory-guidance.md`, the `this factory:` section of a
brief), and the repository's own catalogue (skills as `SKILL.md` with
scripts beside it, tools as packages in a `default.nix`). Its split of a
goal is lines in its outcome, because outcomes are what the decider
reads; a policy line it wrote tells the decider to file them. It never
speaks a verb: assignment stays the decider's, and a manager that
assigned would be a second decider in a cage that also edits the
repository, which is the split ADR-034 exists to prevent.

**5. The skill says what is live when.** Guidance reaches a brief from
the clone with no build; policy, skills and tools reach a cage at the
next machine build from the commit the operator pins, and none can be
loaded in the session that wrote it (ADR-031, ADR-040). A change is
warranted by a symptom that appears in more than one thread; one
occurrence is a task's own trouble.

**6. The example declares it.** `examples/factory-project` gains a
`manager` role providing `plan`, a `plan` stage between `design` and
`build`, and `consults.manager = [ "architect" ]`.

## Consequences

A role that writes no code no longer carries a builder's voice, and the
builder's voice is one paragraph shorter. `fabriek show` orders begin
with `committer`; `check.bats` and `catalogue_cli.bats` assert the new
orders.

The manager's loop is slow by design: write, merge, wait for the
operator's next build, read the cycle after. Guidance is its only lever
without a build. That is ADR-031's cost, paid where it belongs.

The `this factory:` section of a brief is described in
`role-guidance.md` and read by `fabriek_factory_guidance`, but nothing
composes it into a brief yet: the executor's brief has `record:` and
`new since you last looked:` and no guidance section. The manager's
prompt describes the design; wiring it is an item for `docs/roadmap.md`,
not this record.

A split lives in one outcome, flattened to one line in the decider's
board view. Long splits read badly there; a manager that wants more than
a handful of tasks from one goal should file a goal per group, through
the policy, rather than one outcome of twenty lines.

## Verification

```bash
nix develop --command bats tests/command/catalogue_cli.bats
nix develop --command bats tests/command/check.bats
nix develop --command bats tests/command/catalogue.bats
nix develop --command bats tests/unit/repo_declaration.bats
docmeta-check docs && docmeta-tracker --check docs
```

`catalogue_cli.bats` shows `architect`, `reviewer` and `manager` and
asserts each orders as `committer, <name>` with no `## developer` and no
"Test first."; shows `manager` and finds the policy, the guidance and
"next machine build" in its prompt; lists `committer`, `manager` and
`workflow-tuning`. `check.bats` composes a role from the example's
specialists and reads `committer, developer, java, springboot, python`.
`repo_declaration.bats` validates the example with its `manager` role and
`plan` stage.
