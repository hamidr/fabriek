---
id: ADR-035
title: The loop is a pi extension, and loop and agent share a uid
status: proposed
date: 2026-09-12
status_date: 2026-09-12
summary: the actor loop is a pi extension shipped with the machine; it shares the agent uid so the budget stays at the proxy
depends_on: [ADR-029, ADR-030, ADR-033]
supersedes: [ADR-021, ADR-028]
superseded_by: []
---

## Context

ADR-028 kept the loop outside the agent's uid so that what the loop recorded
was not the agent's to rewrite, and ADR-021 had the loop poll the record and
check its own budget. Both assume a cooperating agent somewhere: the loop
trusts its own reading of a budget file, and the ledger it writes is the
evidence.

The threat model ADR-033 restates drops that. If nothing an agent's side
writes is evidence, the loop gains nothing by living outside the agent's
uid, and it loses pi's extension surface: `--mode rpc` already gives the
event stream, `steer`, `follow_up` and `abort`, and an extension gets
`registerCommand`, `registerFlag`, `tool_call`, `tool_result` and
`sendMessage` with delivery `steer`. ACP was examined and rejected on a
measured ground: its client-to-agent surface has no method that injects a
message into a running turn.

## Decision

**1. The loop is a TypeScript extension of ours, loaded by pi's `jiti`.** It
subscribes to the mailbox, announces `ready`, opens a fresh pi session per
task, reads the issue, comments the outcome, rewrites the role's memory, and
publishes turn and tool events to the bus. Background resources start at
`session_start` and are torn down at `session_shutdown`.

**2. It joins ADR-030's floor.** It ships with the machine in the directory
`PI_CODING_AGENT_DIR` names, bound read-only, and cannot come from the
project's flake: a repository that forgets it is a factory whose roles do not
start. ADR-029 point 3 hardens: the loop is a pi extension, so a role runs pi
or has no loop.

**3. Loop and agent are one process under one uid.** ADR-028 is spent on
purpose. What the loop writes is as trustworthy as the agent, so the budget
lives at the proxy (ADR-037) and ADR-021 point 5's self-checked budget is
deleted with the threat model.

**4. The pi process is long-lived; the session is per task.** Context does
not bleed between tasks. The role's memory is one issue on the forge
(ADR-036), read at session start and rewritten at session end.

**5. The agent makes its own commits.** Deciding what constitutes one logical
change is judgement and belongs in the cage. The extension checks the branch
namespace, the signature and that a commit exists before `done`, as advice;
only the executor's repetition of those checks counts (ADR-034 point 4).

**6. Mid-turn steering** reaches the extension's inbox and becomes
`pi.sendMessage()` with delivery `steer`, queued into the running turn at the
next tool boundary.

## Consequences

ADR-021 and ADR-028 are superseded whole. ADR-027 point 4's promise that a
role cannot lie about who it is no longer holds for anything the loop writes,
which is why ADR-038 drops the ledger. pi has no API stability statement, so
the extension is pinned with pi and changes with it.

## Verification

Extension scenarios (docs/roadmap.md 3.2), driven against a stubbed bus and
a stubbed Forgejo: `ready` carries the declared capabilities; an assignment
pointer opens a fresh session; the memory issue is read before the first
turn and rewritten after the last; a Valkey restart is followed by a
re-announce; an outcome without a commit is reported as advice and not
withheld.
