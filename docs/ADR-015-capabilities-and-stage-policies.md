---
id: ADR-015
title: A stage needs a capability and states its own policy; roles provide capabilities
status: implemented
date: 2026-09-03
status_date: 2026-09-04
summary: stages name a capability, roles declare what they provide, and each stage states its own entry and exit policy
depends_on: [ADR-010, ADR-011]
supersedes: []
superseded_by: []
---

## Context

PRD-003 fused two things a Kanban team keeps apart. A stage of a pipeline
names a role, and a role owns exactly one stage, so a column in the flow and a
worker doing the work are the same object.

That fusion has a measured consequence. A role holds one worktree and git
allows one branch per worktree, so a role works one task at a time. A stage
that fans out into three tasks therefore queues them behind its single role,
which makes the `fanOut` flag close to decorative: it produces three tasks and
no more parallelism than one.

It has a second consequence in the declaration. Adding a second builder means
editing the pipeline rather than adding a worker, because capacity is expressed
as pipeline structure.

There is a third gap, and it is the one that has been an open question since
the roles were named. The architect and the reviewer have defined authority --
one refines documents and never accepts, the other decides what integrates --
and the builder has none. Nothing anywhere says what a builder is for, because
a stage carries no statement of what finishing means there. Readiness is
checked once for a whole workflow and "done" means only that an outcome was
recorded, which is the same sentence at every stage of every pipeline.

## Decision

**1. A stage names a capability; a role declares what it provides.** A stage
says `needs = "build"`, and any role whose `provides` includes `build` may take
its tasks. A column is then a step in the flow and a role is a worker with a
cage, a uid and a worktree, which are different things and are declared
separately.

**2. Fan-out parallelises.** Three tasks at a stage go to as many capable roles
as are idle, rather than queueing behind one. Capacity is added by declaring
another role rather than by editing the pipeline.

**3. Among idle capable roles, the first in declaration order takes the task.**
Deterministic, so a factory replays the same way twice. Fairness is not
attempted; if that proves wrong it is a rule to change rather than a structure.

**4. A task sticks to the role that took it.** Taking records the taker, and
every later attempt goes to that role. The branch stays in the namespace of the
role allowed to write it, so a retry continues the first attempt's commits
instead of starting from nothing, and the ref partition of ADR-010 needs no
exception. A busy role holds its own retries; its peers stay free for new work.

**5. A stage states its entry policy, and it is enforced.** `ready` lists the
fields a task must carry before that stage may take it. The supervisor checks
presence and refuses with the missing name, which is a metadata check and reads
nothing anyone wrote.

**6. A stage states its exit policy, and it is not enforced.** `done` is prose
handed to the role in its brief. Judging whether work meets a bar is reading
content, which belongs in a cage, so this is written where the judge will read
it rather than pretended to be a rule.

**7. No stage declares a WIP limit.** How many tasks a column can have in
flight is how many roles provide its capability, because each works one task at
a time. A declared limit could only bite below that number, and a second number
that usually constrains nothing is the trap already hit with the machine-wide
concurrency cap.

## Consequences

What a builder is stops being undefined and stops being nixcage's business. It
is whatever its stage's `done` says, written by whoever declared the pipeline,
in the repository they own.

The declaration breaks. `role` becomes `needs`, and roles gain `provides`.
PRD-003 is implemented, so this is recorded as its own decision with amended
requirements rather than as an edit pretending it was always so, and a factory
declared the old way must be rewritten rather than silently reinterpreted.

The task store gains the role that took a task, which was previously the same
as its stage and is now separate. Every place that read a stage's role now
resolves a capability to a role at the moment work is taken.

Ordering by declaration means the first capable role does most of the work
while any of its peers is idle. That is a real skew and it is accepted for now,
because the alternative is a scheduling policy nothing yet needs and every
scheduling policy is easier to add than to remove.

A role providing several capabilities can be pulled into different stages of
different workflows, which is the flexibility a Kanban team has and a fixed
pipeline does not. It also means one busy generalist can become the bottleneck
for several columns at once, which the record will show and nothing prevents.

## Verification

The design was modelled before it was built, because a stage naming a role gave
two properties for free that a stage naming a capability has to earn: that
every task has someone who can work it, and that a role never runs two tasks at
once.

Alloy carries capabilities, what each role provides, and attempts -- attempts
rather than a single taker field, because stickiness is a claim about several
of them and with one field it would hold by construction. `alloy6 exec
models/factory-structure.als`: ten checks UNSAT at scope 6, and the fan-out and
generalist witnesses SAT. Removing the two mechanism facts turns all three new
checks SAT, so they are not vacuous.

Quint replaces its owner table with a resolution made when a task is taken and
keeps the roles a task has actually run on. `quint run
--invariant=allInvariants --max-steps=60 --max-samples=50000`: no violation. A
mutation handing a retry to an idle peer violates the stickiness invariant, and
the fan-out witness violates its own negation in 19ms.

The rest was measured in a VM, with two roles providing `build` and a stage
needing it.

Two tasks filed at that stage and started twelve seconds apart ran at the same
time, one taken by each role: `task-0001 running backend` and `task-0002
running frontend`. Both settled. That is the consequence this decision exists
for, and the queueing it replaces was itself only visible by running a factory.

A third task was taken by `backend`, timed out, and returned to `ready` with
`backend` still recorded. Started again with `frontend` idle, it went to
`backend` a second time and its attempt count reached two.

A task filed without acceptance criteria stayed `proposed` and the refusal
named the field: `task-0004 is missing acceptance`. The stage's `done` text
reached the brief verbatim, under `done at this stage means`.

A workflow whose stage needs a capability no role provides is refused when work
is filed for it, naming the capability and the stage rather than failing later
inside a cage.
