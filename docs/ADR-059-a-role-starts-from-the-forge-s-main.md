---
id: ADR-059
title: A role's branch starts from the forge's main, and moves when its work has been merged
status: proposed
date: 2026-09-16
status_date: 2026-09-16
summary: worktrees are cut from the clone's first HEAD and never move; cut and re-cut them from the forge's main instead
depends_on: [ADR-010, ADR-032, ADR-036, ADR-054, ADR-057]
supersedes: []
superseded_by: []
---

## Context

ADR-032 clones origin onto the pool once. `fabriek_factory_clone_ensure`
(`modules/factory-clone.sh`) clones when the directory is absent and never
fetches after; under ADR-057, render fetches the pin on every `up`
(`fabriek-container`, `cmd_factory_render`), which brings the pinned
commit and nothing else. The clone's HEAD is the `supervisor` branch, cut
from origin's HEAD at the first clone.

A role's worktree (`fabriek_role_worktree_ensure`,
`modules/role-worktree.sh`) is `git worktree add -b <role>/work` from that
HEAD, made once per role and kept for the factory's life. The executor
(`factory/src/executor/core.ts`, `workBranch`) pushes that one branch to the
forge and opens a pull request from it at every done; the operator merges
on the forge; `mirror` (`factory/src/executor/git.ts`) fetches the forge's
`main` into the clone and pushes it to origin.

So three mains exist and none reaches a role. Origin's `main` moves under
the operator's hand and the clone learns of it only at `mirror`. The
forge's `main` is where the factory's own work lands and the clone learns
of it only at `mirror`. The clone's `main` is what `mirror` last wrote. A
role's branch was cut from none of them: from `supervisor`, at the first
`up`, and every commit since, of the operator's or of another role's,
is invisible to it until it merges something by hand, which no role is
told to do.

`tests/manual/specialist.sh` found the first symptom (ADR-054):
`docs/factory-guidance.md` committed after the first `up` never reached
a brief, because the actor reads it from the worktree. The larger one is
that a role's second task starts on top of its first task's commits,
merged or not, and its pull request carries both.

## Decision

**1. A role's branch is cut from the forge's `main`.** The forge is the
board and the record (ADR-036), and its `main` is what the factory has
integrated. A worktree made for the first time is `worktree add -b
<role>/work <forge main>`, fetched into the clone as `refs/remotes/forge/main`
by the machine program before the worktree is made. Not from origin: what
origin has that the forge does not is the operator's unpushed work, which
reaches a role by being pushed, the rule ADR-032 already sets.

**2. The branch moves when its work has been merged.** When the executor
assigns a task to a role whose branch has no commit that the forge's
`main` lacks (`git rev-list forge/main..<role>/work` is empty), it resets
the branch to `forge/main` before the assignment is sent, and the attempt
line records the tip it starts from, as it does now. A branch that still
carries unmerged commits is left where it is: the operator has not taken
them and the role may be asked to change them. Nothing merges, rebases or
force-pushes on a role's behalf; the pull request the executor opens is
still the one place the work is offered.

**3. The clone fetches the forge's `main` at every `up` and before every
assignment.** Two fetches of one ref from a forge on the same machine; the
second is what makes point 2 current. Origin is fetched for the pin, as
ADR-057 has it, and for nothing else; the clone's own `main` stays what
`mirror` writes.

**4. `supervisor` goes.** The clone's HEAD is cut from nothing a role
starts on; the branch exists so the clone has a HEAD, and a detached HEAD
at the pin serves that. `fabriek_factory_clone_branch` is deleted with it.

## Consequences

A role's first task starts on what the factory has integrated, and its
second task does not carry its first. A brief reads the guidance the
repository has now (ADR-054). A role whose pull request was closed unmerged
keeps its commits until the operator merges or the branch is reset by hand;
that is the case point 2 leaves alone on purpose, and `fabriek enter` is
where a person deals with it.

The executor gains one git operation per assignment and one more case in
which an assignment is refused: a reset that fails (a worktree with
uncommitted changes, a fetch that cannot reach the forge) refuses the
assignment with git's message, as a missing profile refuses a session.
`git.ts` grows `resetTo(branch, ref)` and `fetchMain()`; `core.ts` calls
them before the attempt line is written; `seam.bats` is untouched, since
the session line does not change.

## Verification

Executor scenarios against the fake git (`factory/src/executor`): a role
with nothing unmerged is reset to the forge's `main` before its attempt
line; a role with an unmerged commit is not; a reset that fails refuses
the assignment. Machine program scenarios (`tests/command/prepare.bats`,
`tests/unit/role_worktree.bats`): the worktree is cut from
`refs/remotes/forge/main` when it exists and from the pin when the forge
has no `main` yet; `supervisor` is no branch of the clone. On a machine,
`tests/manual/specialist.sh`'s guidance scenario, which is what found this:
a `docs/factory-guidance.md` committed and merged after the first `up`
reaches the next brief.
