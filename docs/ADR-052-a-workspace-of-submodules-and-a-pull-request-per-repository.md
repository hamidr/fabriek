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

Three facts from git shape the design. A worktree of a superproject does
not share its submodules' git directories with the superproject: a
submodule checked out inside a worktree is cloned again under that
worktree's administrative directory, measured on git 2.55 as
`.git/worktrees/<name>/modules/<path>`, which the role already owns
after ADR-010's `chown`. A submodule pointer is a commit on the
superproject, so a change in a module is recorded by two commits on two
branches, and the superproject's commit is only meaningful once the
module's is on the module's `main`. And git refuses to serve a
repository owned by another user unless told it is safe, so the
executor reading a role's private clone is a case ADR-010 met with
libgit2 and meets again here.

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
`git submodule update` inside the worktree, with `--reference` to the
factory clone's module git directory so the role's clone holds only the
objects it makes, they land under the worktree's administrative
directory, which `fabriek_role_worktree_ensure` already hands to the
role's uid. No new ACL, no new ref partition: a role may write any ref
of its private module clone, `main` included, and nothing of it leaves
except what point 5 fetches. The invariant that `main` is writable by
nobody in a cage (ADR-036 point 9) holds at the forge, where only the
executor pushes and pushes only `<role>/work`; `role-guidance.md` says
so for modules rather than claiming the filesystem enforces it there.
On every entry, `fabriek_role_worktree_ensure` fetches the factory
clone's module refs into the private clone under `refs/remotes/factory/`,
so a reviewer's worktree sees the builder's module branch the way it
sees the workspace's today through the shared refs.

**4. One branch name across the repositories.** A role's work on a task
is `<role>/work` in every module it touched and in the workspace, where
it records the module's new pointer with one commit after the module's
commit. `role-guidance.md` says so. A role that commits in a module and
never bumps the pointer has left half the change; the trace (ADR-051)
and the reviewer see it.

**5. Done is judged across the repositories.** Before it judges, the
executor fetches `<role>/work` from the role's private module clones
into the factory clone's module git directories, with the private clone
named `safe.directory` for that one command, since git refuses to serve
a repository owned by another user. `commitsSince` is then "a commit on
`<role>/work` in any module or the workspace since the attempt began";
the attempt line records the tip per repository.

**6. `push <role>` fans out.** For each repository where `<role>/work`
is ahead of `main`: push to the forge and open a pull request. The
workspace's pull request body lists the module pull requests it waits
on, by number. One verb, no change to the vocabulary; the decider does
not know there are modules.

**7. Merge order is the operator's, in Forgejo,** modules first, then
the workspace, because the workspace's pointer commit is reachable from
the module's `main` only after the module's merge. Nothing merges for
the operator; ADR-036 point 6 stands. The workspace pull request names
the module pull requests it waits on, and merging it first is a mistake
point 8 catches before anything outside sees it.

**8. `mirror` pushes each repository to its own origin,** the URL
`.gitmodules` names, with the operator's credential for that origin
from `config.toml`, since N origins on N hosts are not one credential;
the record goes with the workspace only. Before it pushes anything,
`mirror` checks for every module that the workspace `main`'s pointer is
an ancestor of the module's `main` (`git merge-base --is-ancestor`) and
refuses naming the module when it is not: a workspace pushed while its
pointer names a commit only the machine's forge holds is a dangling
submodule for anyone who clones from origin, which is the bad merge
PRD-003 says nothing outside may see. The refusal is the operator's cue
to merge the module or revert the workspace. One board, one record, N
origins.

**9. A module has a name.** Its path in `.gitmodules` may carry `/`;
its forge repository, its branch lines and its trace lines need a name
`fabriek_name_ok` accepts. The name is the path with `/` replaced by
`-`; a path that still does not pass, or two paths that become one
name, is refused at `check` naming both. A submodule inside a submodule
is refused there too, by path; nested workspaces are not this record.

**10. The build and `check` fetch the modules.** The machine's source
input and `check.sh`'s `git+file://<repo>?rev=` gain `submodules=1`, so
a repository catalogue (ADR-042 point 3) or a lockfile for ADR-046's
cache that lives in a module is seen. The machine build's source is N
repositories deep; the lock pins one commit and that commit pins the
rest.

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
ADR-036 points 2, 5, 7 and 8 stand and apply per repository: a role is
a read collaborator on every module repository too, though it reaches
the module's branches through its private clone and not the forge.
`forge.sh`, `factory-clone.sh`, `role-worktree.sh`, `check.sh`,
`git.ts`, `forge.ts`, `role-guidance.md` and the machine flake ADR-040
generates change; `ls`, `show`, the decider and the vocabulary do not.

Disk is bounded by `--reference`: a role's private clone holds the
objects it makes and reads the rest from the factory clone's module
directory, root-owned and readable, which is what ADR-010 already
relies on for the shared `objects`.

`up` grows by a clone and a push per module, on the operator's side and
with the agent, once. The machine's build is unchanged: the modules'
commits are pinned by the workspace commit the lock names.

Two things left open, to be measured on the machine before
implementation: that the executor's fetch from a role-owned clone runs
as root with `safe.directory` and nothing more (point 5), and that
`--reference` survives the module directory being on a dataset of its
own when the worktree is one. Point 3's placement is measured on this
host's git; the machine's git is the one that counts.

## Plan

1. Read-only: the clone and every worktree carry the modules checked
   out with `--reference`, the module refs fetched on entry, the module
   names checked (point 9), the build and `check` fetching submodules
   (point 10); codegraph indexes the whole tree; no executor change.
   A role sees the sibling code and commits to the workspace alone.
2. Write: points 4 to 8. The journey gains a workspace with one module,
   a task that commits in the module and bumps the pointer, two pull
   requests where it had one, and a mirror refused while the module is
   unmerged and accepted after.

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
directory, the refs fetched under `refs/remotes/factory/`, and the
name mapping with its two refusals. `git.test.ts` and `core.test.ts`
assert `commitsSince` across repositories, the fan-out of `push`, the
module list in the workspace's pull request, and `mirror` refusing on
a pointer the module's `main` does not reach. The journey proves the
two pull requests, the refused and then accepted mirror, and the push
to two origins on this host.
