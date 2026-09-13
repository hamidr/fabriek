---
id: ADR-036
title: Forgejo in the guest is the board, the record and the forge
status: accepted
date: 2026-09-12
status_date: 2026-09-12
summary: issues are tasks, stages are labels, per-role accounts are the authorization matrix; the operator merges and mirrors
depends_on: [ADR-009, ADR-010, ADR-015, ADR-032, ADR-033]
supersedes: [ADR-011, ADR-022]
superseded_by: []
---

## Context

ADR-013 refused a shared database so the record would travel with the
repository; ADR-022 made every role a git-bug writer; ADR-024 then had to
defend git-bug's repository lock, its lock-removal race and its silently
corrupting index. ADR-033 deletes every role as a writer of anything shared,
which dissolves all three, but leaves the question of what the board is.

The factory has a machine and a pool of its own (ADR-019). A forge on that
machine gives issues with labels, per-account permissions, pull requests and
a web UI, none of which would be built as well here. What it costs is the
property ADR-013 bought, and that cost is paid deliberately.

Every permission below was measured on Forgejo 16.0.4 with a read
collaborator holding a `write:issue` token (decision 52 of the redesign log, in the history before roadmap 5.4).

## Decision

**1. The board is Forgejo on the factory's pool.** A task is an issue the
executor files; a stage is a label the executor sets, because Forgejo has no
repository projects API; `blocked` is a label beside it. Every actor reads
the board; only the executor creates, labels, closes and assigns.

**2. A role is a read collaborator with a `write:issue` token.** Measured: it
comments on any issue, edits and deletes its own comments, opens issues and
edits the ones it opened; it cannot edit, close, label or assign a peer's or
the executor's issue, and cannot touch the repository unit. The effective
right is the collaborator permission, bounded further by the scope, and this
is the shape to keep. The decider's token is `read:issue`, which cannot
comment.

**3. A role's memory is one pinned issue, labelled `memory`, opened as the
role** at `cageworks up`, so the role is its poster and may rewrite it and
nobody else may. The operator reads and clears it in the same UI as
everything else; the edit history is the audit. Nothing conferring authority
may live in it.

**4. The bus carries a pointer; the actor reads the issue.** One copy of
every fact, in the place the operator also looks, and the thread the actor
writes back to is the record.

**5. Roles commit locally; the executor pushes and opens the pull request
on Forgejo.** A role holds no credential that can push, pull a private
repository or authenticate off the machine (ADR-009 amended: the issue token
is the one credential it gains). Review happens in the guest.

**6. Merging is the operator's click,** in Forgejo's UI over the forwarded
port. No verb merges, so the executor's refusal of anything touching `main`
stays literal, and factory autonomy ends at an open, tested pull request.

**7. The mirror to origin is an operator action,** `cageworks factory
mirror`: merged `main` and the record, Forgejo's issues and comments
exported as JSON under `refs/cageworks/record`, pushed together. Nothing
leaves the machine until the operator says so, so PRD-003's criterion that a
bad merge is recoverable with nothing outside having seen it is restored.
Forgejo accepts the ref; other forges are unmeasured.

**8. The forge credential for origin is an ordinary push credential** held by
the executor. No platform API, no `gh`, no abstraction.

**9. ADR-010 returns to its original scope.** The widenings ADR-022 and
ADR-023 added are gone, the ref partition is clean, and `main` is writable
by nobody in a cage.

## Consequences

ADR-013 is fully reversed: there is a shared database, it lives on the pool,
and `journalQuota` becomes `recordQuota` to bound it. The record does not
travel with the repository except by mirror, so what was not yet mirrored is
lost with the pool. git-bug leaves the design, taking ADR-022, ADR-024 and
`modules/record.sh` with it; the task store of ADR-014 and `modules/
task-store.sh` go with them; ADR-011's sync with the operator's checkout is
replaced by the mirror, and `modules/integrate.sh` is deleted.

A role can revise its own comments and its memory's history. A factory with
no operator present stops at its pull requests. `cageworks up` must be
idempotent for accounts, tokens, memory issues and labels.

## Verification

`cageworks up` scenarios (docs/roadmap.md 2.3): a second `up` changes no
account, token, issue or label. Executor scenarios (3.3): a stage move is a
label change, a `done` without a signed commit on the role's namespace is
refused, `mirror` pushes `main` and `refs/cageworks/record` in one call. The
decision-52 probe script, rerun against the image the machine pins, must
give the same twenty results.

Status 2026-09-13: the `cageworks up` and executor scenarios above hold
(`tests/command/prepare.bats`, `factory/src/executor/core.test.ts`), and
since 2026-09-13 prepare reads the record back onto an empty board.
`tests/system/journey.sh` drives the board on a real forge (Gitea on a
Mac, Forgejo elsewhere): labels moved, a pull request opened, main and
the record mirrored to origin. It found prepare making no `assigning` or
`assigned` label and putting no `main` on the forge, both fixed. The
decision-52 probe script has not been rerun against the image the
machine pins; that rerun is what keeps this at accepted.
