---
id: ADR-051
title: Every attempt leaves a trace in its thread, and a verdict stage hands it to the manager
status: implemented
date: 2026-09-15
status_date: 2026-09-15
summary: the executor comments a trace per attempt cut from the events and probes streams; a stage may be a verdict
depends_on: [ADR-033, ADR-034, ADR-038, ADR-050]
supersedes: []
superseded_by: []
---

## Context

A manager (ADR-050) improves how a factory works from what its record
shows. The record shows outcomes: what a role said it did. What a role
used to get there is observed but not kept: the loop publishes every
`tool_call`, `turn_start` and `guard_refused` to `events:<role>` on the
bus, the probes publish every exec per uid to `probes`, both streams are
capped, and pi's transcript stays in the role's home where only the
operator reads it (`fabriek log`). ADR-038 says three sources and no
ledger, and stands. What was missing was the cut per attempt, taken
while the sources still hold it, and a moment at which the manager is
handed it.

Two facts constrain the hand-off. The decider assigns and nothing else
does (ADR-034), so the manager is told through a stage the decider
assigns like any other. And the executor takes `done` only with a commit
on the role's branch since the attempt began (ADR-034 point 4), which an
inspection that changes nothing cannot produce; the review stage has the
same shape, and the scripted reviewer in `tests/system/journey.sh`
commits a file to get past it.

## Decision

**1. The actor brackets its attempt on its events stream.** `task_started`
with the issue and the attempt when it takes an assignment, before the
ack; `task_ended` with the status when it reports, before the outcome
comment. Both are claims, like every event, and they are what a trace is
cut between: no clock is shared and no id is recorded anywhere else.

**2. The executor writes one `trace:` comment per attempt.** When it
reads an outcome, before it judges it, it reads `events:<role>` and
`probes` as they stand and comments the summary under its own token:
turns, tools by name with counts, the `bash` commands (first line, at
most a hundred characters), the executables the probes saw for that role
(`comm`), the skills read (`.../skills/<name>/SKILL.md`), and the guard's
refusals with their rule. An attempt the stream no longer holds gets
`trace: not observed` and the reason. The summary is pure over stream
entries (`factory/src/executor/trace.ts`); the executor's only new
interface is `Streams.range`, a read.

**3. A stage may declare `verdict = true`.** Done at such a stage is the
role's judgement and not a change, so the executor asks no commit of it;
everything else about the stage is as before. The declaration's schema
gains the key on both sides (`repo-declaration.sh`, `declaration.ts`).
The example sets it on `review` and on the new `inspect` stage.

**4. The example ends every task at `inspect`.** The manager provides
`inspect` beside `plan`; the stage follows `review` and its gate, so it
never holds up integration. The manager's brief carries the thread and
every trace in it; its outcome is `done` with "nothing to change" and
the reason, or the lever it pulled with the symptom and the threads.
The `workflow-tuning` skill says how a trace is read.

## Consequences

The record now says what every attempt cost in calls and commands,
readable by the manager, the reviewer and the operator from the board,
with no ledger and no fourth source: the comment is taken from the
streams at the one moment both the attempt and the streams are there.

Tokens are not in the trace. The proxy counts per role and not per
attempt; putting a number in the trace would mean the executor holding
a count per assignment across its own restarts. The manager reads spend
from the relay's `spend` events for now.

One more model session per task, at every task. The alternative, an
inspection only for retried or blocked tasks, needs the decider to
count, which it cannot; that is the next step when spend shows the
stage costs more than it finds.

A `trace:` comment is one more executor comment in a thread the actor's
brief renders; the reviewer reads it with the rest. A thread with many
attempts grows by one line per attempt in the board view.

`verdict` on `review` changes what the example's reviewer is held to: a
verdict with no commit is now done there. The journey's declaration
keeps its own stages and its scripted reviewer still commits; nothing
there changed but the thread's shape.

## Verification

```bash
nix develop --command bash -c 'cd factory && npm test'
nix develop --command bats -f verdict tests/unit/repo_declaration.bats
nix develop --command bats tests/unit/repo_declaration.bats
nix develop --command tests/system/journey.sh
docmeta-check docs && docmeta-tracker --check docs
```

`trace.test.ts` cuts between the brackets and counts, names refusals,
takes the latest attempt when an earlier one of the same task is still
on the stream, says not observed when the start is gone, and shortens a
long command. `actor.test.ts` and `bind.test.ts` see the two brackets
around an attempt. `core.test.ts` sees the trace comment follow the
outcome and precede the stage move, and a verdict stage take done with
no commit while `build` still refuses it. `repo_declaration.bats`
accepts `verdict` as a boolean and refuses it as a string. The journey
reads the thread as attempt, outcome, trace, attempt, outcome, trace,
and the builder's trace counting its one tool call.
