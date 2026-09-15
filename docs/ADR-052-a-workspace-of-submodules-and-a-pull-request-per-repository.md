---
id: ADR-052
title: A factory works a workspace of submodules, and its output is a pull request per repository
status: proposed
date: 2026-09-15
status_date: 2026-09-15
summary: the declaring repository pins the others as submodules; one board and record, push and mirror fan out per repository
depends_on: [ADR-010, ADR-011, ADR-020, ADR-034, ADR-036, ADR-040]
supersedes: []
superseded_by: []
---

## Context

A factory is one repository: declared in it (ADR-020), built from its
lock (ADR-040), cloned once (ADR-011), with one board and one record on
the machine's Forgejo and one origin to mirror to (ADR-036). A role's
ref namespace, ACL and worktree are of that clone (ADR-010); the
executor judges done on one branch and `push` opens one pull request.

A product is often several repositories. Today that is several
factories on one host (`fabriek -f`, ADR-048): a machine each, a board
each, a budget each, and no task that can touch two of them. What an
operator expects is one factory over the set, with the output where they
merge it: a pull request on each repository the work touched, because
the repositories are separate on their forge and no forge merges across
two.

Three ways were weighed. Several factories, as now: nothing to build and
no cross-repository task. Sibling repositories named in `fabriek.nix`
with a commit each: the pin lives in fabriek's schema, `check` fetches N
repositories to evaluate, and the machine build has N inputs. A
workspace repository that pins the others as git submodules: the pin
lives in git, everything that is "one" today stays one, and a repository
worked alone keeps working alone. The third is this record.

Two facts from git shape the design. A worktree of a superproject does
not share its submodules' git directories with the superproject: a
submodule checked out inside a worktree is cloned again under that
worktree's administrative directory (`.git/worktrees/<name>/modules/`),
which the role already owns after ADR-010's `chown`. And a submodule
pointer is a commit on the superproject, so a change in a module is
recorded by two commits on two branches, and the superproject's commit
is only meaningful once the module's is on the module's `main`.

## Decision

**1. The factory's repository may be a workspace.** A repository with
submodules declares the factory as any other does; its `fabriek.nix` is
the declaration, its lock is the machine's, its issues are the board and
its `refs/fabriek/record` is the record. A repository without submodules
is a workspace of one and nothing below applies to it.

**2. The clone carries the modules, from the forge.** `factory-clone.sh`
checks the submodules out. At `up`, the operator's side, which holds the
agent, clones each module from the URL `.gitmodules` names and pushes it
to a repository of its own on the machine's forge,
`operator/<factory>-<module>`, made by `forge.sh` beside
`operator/<factory>`; inside the machine every submodule URL is
rewritten to the forge. Nothing in a cage names an origin (ADR-037).

**3. A role's worktree carries the modules as private clones.** Made by
`git submodule update` inside the worktree, they land under the
worktree's administrative directory, which `fabriek_role_worktree_ensure`
already hands to the role's uid. No new ACL, no new ref partition: a
role may write any ref of its private module clone, and nothing of it
leaves except what point 5 fetches. Disk is one object store per role
per module, inside the role's quota.

**4. One branch name across the repositories.** A role's work on a task
is `<role>/work` in every module it touched and in the workspace, where
it records the module's new pointer with one commit after the module's
commit. `role-guidance.md` says so. A role that commits in a module and
never bumps the pointer has left half the change; the trace (ADR-051)
and the reviewer see it.

**5. Done is judged across the repositories.** Before it judges, the
executor fetches `<role>/work` from the role's private module clones
into the factory clone's module git directories. `commitsSince` is then
"a commit on `<role>/work` in any module or the workspace since the
attempt began"; the attempt line records the tip per repository.

**6. `push <role>` fans out.** For each repository where `<role>/work`
is ahead of `main`: push to the forge and open a pull request. The
workspace's pull request body lists the module pull requests it waits
on, by number. One verb, no change to the vocabulary; the decider does
not know there are modules.

**7. Merge order is the operator's, in Forgejo,** modules first, then
the workspace, because the workspace's pointer commit is reachable from
the module's `main` only after the module's merge. Merging the
workspace first is early, not wrong: `main` would point at a module
commit not yet on that module's `main`, and the mirror carries both.
Nothing merges for the operator; ADR-036 point 6 stands.

**8. `mirror` pushes each repository to its own origin,** the URL
`.gitmodules` names, with the operator's credential; the record goes
with the workspace only. One board, one record, N origins.

## Consequences

The unit of a task stays one issue and one role; the unit of output
becomes one pull request per repository touched plus one on the
workspace. A task in a single module still opens the workspace pull
request for its pointer: the cost of the pin living in git and not in
fabriek's schema.

No atomic cross-repository merge exists and none is pretended. The
workspace pointer and the merge order are the substitute, and a mirror
between the module's merge and the workspace's shows a workspace `main`
one pointer behind, which is a state git already has a name for.

ADR-011 point 1 stands for the workspace and gains N module git
directories under the one clone; point 2 stands unchanged for the
workspace and is not needed for the modules, which are private clones.
ADR-036 points 5, 7 and 8 stand and apply per repository. `forge.sh`,
`factory-clone.sh`, `role-worktree.sh`, `git.ts` and `forge.ts` change;
`check`, `ls`, `show`, the decider and the vocabulary do not.

`up` grows by a clone and a push per module, on the operator's side and
with the agent, once. The machine's build is unchanged: the modules'
commits are pinned by the workspace commit the lock names.

Two things left open, to be measured before implementation: whether
`git worktree add` followed by `git submodule update` in the worktree
lands the module clones where point 3 expects on this git, and what a
submodule with a submodule of its own does (nested workspaces are not
in this record; a first implementation refuses them by name).

## Plan

1. Read-only: the clone and every worktree carry the modules checked
   out; codegraph indexes the whole tree; no executor change, no ACL
   change. A role sees the sibling code and commits to the workspace
   alone.
2. Write: points 4 to 8. The journey gains a workspace with one module,
   a task that commits in the module and bumps the pointer, and two pull
   requests where it had one.

## Verification

```bash
nix develop --command bats tests/unit/factory_clone.bats tests/unit/role_worktree.bats tests/command/prepare.bats
nix develop --command bash -c 'cd factory && npm test'
nix develop --command tests/system/journey.sh
docmeta-check docs && docmeta-tracker --check docs
```

The clone and worktree tests drive the shell modules against a
fixture workspace with one submodule and assert the checkout, the URL
rewrite and the private clone under the worktree's administrative
directory. `git.test.ts` and `core.test.ts` assert `commitsSince` across
repositories, the fan-out of `push` and the module list in the
workspace's pull request. The journey proves the two pull requests and
the mirror to two origins on this host.
