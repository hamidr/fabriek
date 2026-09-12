---
id: ADR-034
title: The supervisor splits into a caged decider and an uncaged executor
status: proposed
date: 2026-09-12
status_date: 2026-09-12
summary: a caged model judges what happens next and asks; an uncaged executor validates each verb and acts
depends_on: [ADR-015, ADR-030, ADR-033]
supersedes: []
superseded_by: []
---

## Context

ADR-033 gives the factory one sender of work. Something has to decide what
that sender sends: which ready actor gets which task, whether a failure is
worth another attempt, whether a task is hopeless, whether something should
be filed or blocked. PRD-003's supervisor refused all of that as content and
resolved a taker by declaration order; PRD-005 made judgement the agent's
own and dispatched nothing.

Judgement is reading content, and reading content is what a cage is for.
Holding credentials is what a cage is not for. The two halves of the old
supervisor want different treatment, so they become different things.

## Decision

**1. The decider is a caged actor,** provided by the machine rather than
declared by the repository, for ADR-030's reason. It reads Forgejo, the bus
and the declaration, and decides who gets what next, what to retry, what to
block, what to file. It holds a Forgejo token with `read:issue` and nothing
that writes anywhere.

**2. The executor is uncaged and decides nothing.** It holds every
credential: it starts and stops sessions as `nixcage-container enter` argv,
moves labels, pushes branches, opens pull requests, mints tokens, manages
Valkey ACLs, watches units, counts spend, mirrors the record. Written in
TypeScript, in the one package that also holds the extension (ADR-035), so
the command vocabulary and the bus message types are defined once.

**3. The decider acts only by asking, through six typed verbs,** and the
executor refuses whatever the declaration does not permit. `assign <issue>
<role>`: the role exists, provides the stage's capability, is `ready`, the
issue is in a stage, attempts are below `taskAttempts`. `retry <issue>`: as
`assign` to the same role, the previous outcome attached to the brief.
`block <issue> <on-issue>`: a label and nothing else. `file <title-file>
<body-file> <stage>`: files, never argv. `push <role>`: the branch is that
role's namespace. `stop <role>`: aborts the turn, the assignment stays. No
verb merges and no verb records.

**4. The role writes its outcome; the executor moves the stage.** A role's
comment under its own token is the outcome. The executor checks what is
checkable, a signed commit on the role's namespace before `done`, and moves
the label. Two writers of one outcome would be ADR-024's double account by
another route.

**5. The decider's prompt has four parts, and one is the repository's.** The
machine's system prompt (vocabulary, invariants, rules), the declaration as
data, the board and the `ready` set as data, and one policy file
`cageworks.nix` names, bound read-only. The repository states priorities in
words; the worst it can do is bad judgement inside the declared limits.

**6. Testing is a capability a role provides,** assigned like any other
work. No CI service and no runner: a runner spawns containers and reaches a
network, which is the isolation model undone for the most untrusted code.

**7. ADR-015 point 3 is withdrawn.** The first idle capable role in
declaration order no longer takes a task; the decider chooses among the
capable ready ones. Points 1, 2 and 4 to 7 stand.

## Consequences

The first of PRD-003's two invariants changes: "the supervisor is uncaged and
content-blind" becomes "the executor is uncaged and content-blind, and the
decider is caged and reads everything". The second gets more load-bearing:
nothing a role writes reaches a command line, and that now governs the
decider's output, because its decisions drive the thing holding credentials.

The decider runs a model, so the supervisor's own thinking is a budget line,
and a dead decider is a stopped factory the executor restarts. It is an
injection target: it reads every comment and memory, and `stop`, `block` and
`file` act on peers. The declaration bounds what; nothing bounds how often.
Accepted rather than repaired, because an operator confirmation on those
verbs makes the operator the loop again. The policy file is trusted content:
whoever commits it steers the decider.

## Verification

Executor scenarios (docs/roadmap.md 3.3): every verb with each argument
that the declaration refuses, and the refusal named. Decider scenarios
(3.4): a recorded board yields a valid `assign`; an `assign` naming a role
that does not provide the capability is refused by the executor.
