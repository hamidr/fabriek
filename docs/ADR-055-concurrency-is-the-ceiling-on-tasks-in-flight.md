---
id: ADR-055
title: concurrency is the ceiling on tasks in flight, held by the executor and used to size every cage
status: implemented
date: 2026-09-15
status_date: 2026-09-15
summary: assign is refused past resources.concurrency; a cage is sized by it; absent, it is the role count
depends_on: [ADR-019, ADR-020, ADR-034, ADR-053]
supersedes: []
superseded_by: []
---

## Context

`resources.concurrency` has been in the declaration since ADR-020 as a
count the operator may cap. The one thing that read it was the cage
sizing in `machine-plan.sh`: a cage's memory and cpu bound is the
declared memory and cores divided by `concurrency`, default 1, with the
test saying the intent: "with no concurrency declared, one cage at a
time gets everything". That held when a supervisor ran one task at a
time. Since ADR-034 the executor starts every role's session at `up`
and keeps it running, so with nothing declared N cages are each bounded
by the whole machine, and nothing anywhere held the number of busy
roles to the declared count: no executor or decider code read
`concurrency`. A declaration saying `concurrency = 3` with five roles
said nothing that anything enforced.

ADR-053 point 5 met this from the other side and refused a declared
`concurrency` below the expanded role count, on the premise that every
cage is busy and sizing for fewer is wrong. The premise is the problem:
an idle pi session waiting on its mailbox costs little, and what the
machine has to carry is the busy ones. Two honest readings remained:
make the number the divisor only, absent meaning the role count; or
make it a ceiling something holds. This record takes the second, and
withdraws ADR-053 point 5.

## Decision

**1. `concurrency` is how many tasks may be in flight at once.** In
flight is a role holding work: an issue `assigning` or `assigned` to
it. The executor refuses `assign` when that many roles hold work:
`the factory's concurrency is 3 and 3 roles hold work`. `retry` goes
through `assign` and is refused the same way. Zero, which is what the
build writes when nothing is declared, means no ceiling beyond one task
per role.

**2. The decider is told.** The declaration section of its prompt
carries `tasks in flight at once: N`, or `one per role`, and the rules
say an assign past it is refused, so the decider finishes or frees a
task rather than asking for what it will not get.

**3. A cage is sized by the same number.** `fabriek_cage_bounds` divides
memory and cores by `concurrency`; when none is declared, by the number
of roles, since every role's session runs and any may be the busy one.
A single role with nothing declared still gets everything.

**4. ADR-053 point 5 is withdrawn.** A `concurrency` below the expanded
role count is the ordinary case: five roles, three busy at once. The
schema check goes, and its scenario is replaced by one accepting the
smaller number. The example says `concurrency = 3` again, with the
comment saying what it now means.

## Consequences

The number means one thing in three places: the decider reads it, the
executor holds it, the machine sizes by it. A declaration with
`concurrency = 3` and five roles has at most three busy cages, each
bounded at a third of the machine, and two idle sessions inside the
same ceilings costing what an idle process costs.

A factory that never declared `concurrency` changes on its next build:
each cage is bounded at a share of the machine instead of the whole,
which is what running N sessions always meant and the sizing never
said. An operator who wants one busy cage at full size declares
`concurrency = 1` and gets the refusal that makes it true.

The decider can still ask past the ceiling; the refusal is one more
line it reads and learns from, like every other. Nothing queues on its
behalf: a task the ceiling holds back is on the board at its stage,
and the decider asks again when a role frees.

The operator's cap (`config.toml`, `[caps] concurrency`) clamps the
declared number as before; a clamp lowers the ceiling and the
divisor together.

## Verification

```bash
nix develop --command bash -c 'cd factory && node --test dist/executor/core.test.js dist/decider/core.test.js'
nix develop --command bats tests/unit/machine_plan.bats tests/unit/repo_declaration.bats tests/command/check.bats
docmeta-check docs && docmeta-tracker --check docs
```

`core.test.ts` refuses the second assignment under `concurrency: 1`
naming the number and the holder, takes it after the first task ends,
and takes both with nothing declared. The decider's test reads the
count and the `one per role` wording off the prompt.
`machine_plan.bats` divides by three roles when nothing is declared and
by nothing for one. `repo_declaration.bats` accepts a `concurrency`
below the role count.
