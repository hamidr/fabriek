---
id: PRD-006
title: A factory that runs itself, and an operator who watches from one place
status: implementing
date: 2026-09-12
status_date: 2026-09-12
summary: a filed goal is assigned, worked, tested and opened as a pull request with nothing typed after it, trusting no cage
depends_on: [PRD-004]
supersedes: [PRD-005]
superseded_by: []
phases_total: 6
phases_done: 5
---

## Problem

An operator with a factory today types every run. `cageworks task run` starts
one session; when it ends, the operator reads what happened and types the
next one. PRD-003 built a factory whose supervisor is content-blind and
whose roles cannot start work, which is safe and is also why nothing moves
on its own. PRD-005 proposed to let each agent take its own work by a leased
claim, and its own design gates found that the claim protocol was a
distributed mutual-exclusion problem resolved by the party it constrains.

Underneath both is a threat model that was never stated. Several mechanisms
(a self-checked budget, a ledger the agent's own uid writes, an offline flag
the agent honours) only work if the agent cooperates. An agent may try to
escape, exfiltrate and forge; a factory built on its cooperation is not
isolating anything.

The operator also has no single place to look. The record is inside a git
clone on the machine, the console is a pane that dies with its terminal, and
what a role spent is in a journal nobody exports. The redesign log, in the
history before roadmap 5.4, re-derived the factory from the threat model;
this document is the product that re-derivation describes.

## Users

- **The operator** files a goal, watches the factory work it from one
  client, steers a role mid-turn when it must, merges what it accepts, and
  mirrors the result to the repository's origin. They never type a run.
- **A role** is an agent in a cage that is told what to do, does it, says
  what it did, and asks for the next thing. It holds nothing that reaches
  outside the machine.
- **The decider** is a role the machine provides, whose work is choosing.
- **The repository's maintainers** declare the factory, its workflows and
  a policy for the decider, and see the record arrive beside the code.

## Goals

1. A goal filed by the operator is assigned by the decider, worked by a
   role, tested by a role providing the testing capability, opened as a
   pull request, and mirrored to origin on the operator's word, with no
   command typed after the goal.
2. Every mechanism that only works if an agent cooperates is gone, and the
   ones that replace it are proved on a real machine: a cage has no route
   off the machine, cannot reach a peer, cannot forge its source address,
   and its spend is attributed to it.
3. The operator has one client that shows what is happening now and lets
   them intervene, and every intervention is recorded.
4. Nothing leaves the machine before the operator says so, so a bad merge
   is recoverable with nothing outside having seen it.
5. The record travels with the repository again, as a mirrored ref, so
   tearing a factory down does not destroy the account of why the code
   looks as it does.

## Non-goals

- Merging by the factory. `main` is written on a human click and nowhere
  else. A factory with no operator present stops at its pull requests.
- Priorities, deadlines or any scheduling richer than the decider's
  judgement inside the declared limits.
- A CI service or runner. Testing is a capability a role provides.
- Web access for a role. The repository and its devShell are its sources.
- Compatibility with the design PRD-003 built. This is greenfield on a
  branch, and the suite that covers today's factory stops applying when the
  branch lands.
- A cage that is not pi. The loop is a pi extension, so a role runs pi or
  has no loop.

## Success criteria

1. `tests/manual/parity.sh` passes on a real machine: the journey of goal 1,
   step by step, with a check after each.
2. `tests/manual/isolation.sh` passes on a real machine: the four properties
   of goal 2, plus the soft limit stopping routing and the hard limit
   refusing at the proxy.
3. Every verb the executor accepts is reachable from the TUI without the
   web UI, merge excepted.
4. A second `cageworks up` on a running factory changes nothing on the
   machine.
5. A deliberately lying actor at reconciliation cannot cause a task to be
   assigned to two roles, shown by the executor's own scenarios.
6. `docs/architecture.md` describes the branch, and `docs/roadmap.md` shows
   every item's exit held.

## Requirements

### The machine

- A factory's declaration is built into its machine's image from a
  per-factory lock, and a change to it is a rebuild (ADR-040).
- Each cage has its own address on a per-factory bridge and no route off
  the machine; two bridge rules make spend attribution proof (ADR-037).
- The machine runs the board, the bus, the proxy and the probes; the
  operator's host runs a launcher and a client and nothing that decides
  (ADR-039).

### Work

- An actor announces `ready` and is sent work by one sender; it never takes
  work (ADR-033).
- A caged decider chooses; an uncaged executor validates every verb against
  the declaration and acts (ADR-034).
- A task is an issue on Forgejo on the machine, its stage a label; a role
  comments its outcome and the executor moves the stage (ADR-036).
- An actor that cannot finish blocks in place and says so; the operator can
  see who is blocked on whom.
- The loop is a pi extension that ships with the machine (ADR-035).

### Cost and observation

- Spend is counted at the proxy per role and per factory against a declared
  ceiling the operator caps; a soft limit stops routing and a hard limit
  refuses (ADR-037).
- Three sources, never merged: the thread, the proxy, the probes. Nothing
  persists the event stream (ADR-038).

### The operator

- One TUI covering every operation, reading a JSONL relay and writing
  through the executor (ADR-039).
- Merge is a click on Forgejo; mirror to origin is an operator command.
- Each role's memory is visible and clearable.

## Constraints

- The three nixcage primitives and nothing else cross the boundary
  (ADR-018); the two interface changes ADR-037 needs land upstream first.
- Every component is built behaviour first: scenarios written and seen
  failing before code (docs/roadmap.md, Method).
- The executor, the extension, the relay and the TUI are one TypeScript
  package built through the flake; the launcher stays bash and bats-tested.
- ASCII throughout; `seam.bats` remains the gate on what a role session is.

## Risks

- **A hung-but-alive actor holds its task forever.** Accepted; the operator's
  blocked view is the remedy.
- **The decider is an injection target** with verbs that act on peers.
  Bounded by the executor's validation, not by rate. Accepted.
- **The record lives on the pool** until mirrored; what was not mirrored is
  lost with it.
- **The parity bar is the suite.** Most of what is known to work today stops
  being tested on day one of the branch, so the bar exists before the
  branch does.
- **pi has no API stability statement.** The extension is pinned with pi.
- **Forgejo permissions were measured on one version.** The probe is rerun
  against the pinned image.

## Open questions

- The relay's exact JSONL shape (3.5).
- The record export format and whether it is re-imported on a fresh
  machine (2.3, 3.3). Decided: `issues.json` on `refs/cageworks/record`,
  read back by prepare onto an empty board; comments are not exported.
- The `probes` stream's cap and whether the proxy's metadata log joins the
  bus (2.2).
- Whether a non-Forgejo origin accepts `refs/cageworks/record` (5.1).

## Phases

The phases are docs/roadmap.md's, with its exit conditions; that file
carries per-item status and this one the count.

1. **Gates, on `main`.** Roadmap phase 0: the lifecycle model amended, the
   TUI scope settled, these documents, and the two manual scripts written to
   fail for the right reason.
2. **nixcage interface.** Roadmap phase 1: the bridge and address option,
   the no-daemon option, the lock bump, `seam.bats` green on the new line.
3. **The machine.** Roadmap phase 2: the generated flake, the machine
   services, an idempotent `up`, isolation and stop-and-start passing.
4. **The TypeScript package.** Roadmap phase 3: types and validators, the
   extension, the executor, the decider, the relay.
5. **The operator's side.** Roadmap phase 4: the launcher, the deletions,
   the TUI.
6. **Parity and merge.** Roadmap phase 5: parity on a real machine, models
   settled, architecture rewritten, branch merged.

## Design gates

Each phase's exit is a scenario run whose output is recorded in
docs/roadmap.md beside the item. Phases 3 and 6 need a real machine and are
not claimed from a stub.
