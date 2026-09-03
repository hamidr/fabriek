---
id: ADR-010
title: A factory role cage runs under its own uid, name, and signing key
status: implemented
date: 2026-09-02
status_date: 2026-09-03
summary: factory role cages get an allocated uid and a named user, own their worktree, and write only their own refs
depends_on: [ADR-004, ADR-007, ADR-009]
supersedes: []
superseded_by: []
---

## Context

ADR-004 maps a cage onto the owner of the project directory. That was written
when one project meant one cage, and the boundary that mattered was between the
cage and the host.

PRD-003 puts several role cages on one machine, working one repository at the
same time. Under ADR-004 they all map onto the same uid, so the kernel draws no
boundary between them at all: any role can read and write any other role's
worktree, persistent home, and signing key. ADR-009 gives each role its own key
precisely so unattended work is attributable and revocable on its own terms,
and a shared uid makes every key readable by every role, so that attribution
rests on nothing.

The constraint ADR-004 discovered still binds. Nix's libgit2 refuses to open a
repository owned by a different uid than the calling process, and ADR-004
measured that `safe.directory` does not lift it, because libgit2 never consults
that configuration. A cage with its own uid therefore cannot work a tree that
belongs to someone else. What it can work is a tree that belongs to it.

## Decision

A factory role cage runs under its own uid, its own user name, and its own
signing key. An ordinary project cage is unchanged, because its project
directory is the operator's working copy and they use it from the host too.
This amends ADR-004's scope the way ADR-004 amended ADR-003's "no user
namespaces" clause; ADR-004 is not superseded.

**1. A uid per role, from a declared range.** The Nix declaration names a base
and a size. A role is assigned the lowest free uid in that range on first run
and keeps it, recorded in nixcage state. A removed role's uid is not reissued,
so a new role never inherits the file ownership of a dead one. The cage runs
with `--private-users=<role_uid>:1` and ownership shifting off, exactly the
mechanism ADR-004 uses, with the role's uid where the project owner's was.

**2. A name inside the cage.** The session skeleton's `/etc/passwd` names uid 0
as the role rather than as root, so the session's user, its prompt, and
anything that resolves the uid say which role is running. On the host the uid
is a bare number, which ADR-004 already accepted for gids.

**3. The role owns its checkout.** The role's worktree and its administrative
directory `.git/worktrees/<role>` are chowned to the role's uid. The common git
directory stays with the repository's owner. Which repository that is, and
therefore which filesystem all of this lands on, is ADR-011's decision; this one
requires only that it carries ownership and ACLs. Those two paths are what git and
libgit2 actually check, which was measured rather than assumed.

**4. Writes reach the shared object database through ACLs.** A POSIX ACL grants
each allocated role uid `rwX` on the repository's object directory, and a
default ACL makes new objects inherit it. A shared group cannot serve here:
nspawn derives the gid map from the same base as the uid map (ADR-004), so a
cage holds exactly one gid, equal to its uid, and no supplementary groups.

**5. Refs are namespaced, and `main` is writable by no cage.** A role's
branches live under `refs/heads/<role>/`, and that directory and its reflog
directory `logs/refs/heads/<role>/` carry an ACL for the role's uid. Git
creates a ref by writing a lock file in the ref's own parent directory, so a
role can create and move its own branches and nothing else. `refs/heads`
itself, `refs/heads/main`, and `packed-refs` grant no cage write access, which
is what makes "only the supervisor advances `main`" a property of the
filesystem rather than a rule a role follows.

**6. Home, skeleton, and key follow the role.** The persistent home and the
session rootfs skeleton are chowned to the role's uid, the home staying 0700.
ADR-009's signing key is 0400 owned by the role's uid rather than by the
project owner, which is what turns per-role revocation from nominal into real.

## Consequences

Roles are isolated from each other by the kernel. Reading another role's key,
home, or worktree now requires defeating a uid boundary rather than merely
being a process in the same factory.

The object database remains shared authority, and no uid boundary changes that.
Git's object store is content-addressed and shared by design, so any role can
add objects another role will later read. That is unavoidable and mostly
harmless: an object nothing references is garbage. What a role cannot do is
make an object reachable outside its own namespace, because refs are
partitioned and `main` is not writable from a cage.

The partition costs a naming convention. A role's branches must live under its
own prefix, so a role cannot create `refs/heads/hotfix` at the top level, and
tooling that assumes flat branch names sees longer ones. Git itself does not
care, and `packed-refs` is left to the repository owner, which means the
operator or the supervisor packs refs, never a role.

The uid range is a host resource the operator owns. On Linux it must not
overlap real host users; on macOS it lives in the VM's own uid space. Choosing
it badly fails silently, by colliding with an account rather than by erroring.

Losing nixcage state loses the role-to-uid map. Files then carry stale numeric
owners, and recovery is re-chowning the role's worktree, home, and key. Not
reissuing a freed uid keeps a removed role's leftovers from being adopted by a
new role.

ACLs bind a factory to a filesystem that supports them and add `acl` to the
container profile. An ordinary project cage needs neither.

Every ref update a role makes prints `Unable to create packed-refs.lock:
Permission denied` on stderr. Git takes that lock opportunistically, the
operation succeeds anyway, and the exit status is zero. It cannot be silenced
by configuration -- `gc.auto=0` and `maintenance.auto=false` were both tried --
and the one thing that would silence it, granting the role write access to
`.git` itself, is precisely what must not happen: `packed-refs` holds ref
values, so a role able to write it could redefine `main` without ever touching
`refs/heads/main`. The noise is therefore permanent, and the guidance a role
receives has to say that this particular error is expected, because an agent
reading its own stderr will otherwise conclude its commit failed.

Ordinary cages keep every property ADR-004 gave them, including files landing
in the project owned by the user rather than by root.

## Verification

Measured on git 2.55.0 before this was written.

With the whole common `.git` owned by another uid, both layers refuse: `git
status` reports `detected dubious ownership`, and `nix flake metadata` fails
with `repository path '<repo>/.git/worktrees/<role>' is not owned by current
user (libgit2 error code = 7)`. The error names the administrative directory,
not the common directory, which is why point 3 moves exactly that entry.

With the worktree and `.git/worktrees/<role>` owned by the caller and the
common `.git` left foreign, `git status` reports the branch and `nix flake
metadata` resolves the revision. Committing then fails with `insufficient
permission for adding an object to repository database`. Making the git
directory group-writable repaired it in a shell that carried the group, which a
cage does not.

Measured in the nixcage VM on git 2.55.0, on the ext-backed data volume, with
the repository owned by root, the worktree and `.git/worktrees/<role>` chowned
to a foreign uid, ACLs on `objects`, `refs/heads/<role>` and
`logs/refs/heads/<role>`, and no shared group anywhere:

```
setfacl -R -m u:<role_uid>:rwX -m d:u:<role_uid>:rwX <repo>/.git/objects
setfacl -R -m u:<role_uid>:rwX -m d:u:<role_uid>:rwX <repo>/.git/refs/heads/<role>
setfacl -R -m u:<role_uid>:rwX -m d:u:<role_uid>:rwX <repo>/.git/logs/refs/heads/<role>
setpriv --reuid=<role_uid> --regid=<role_uid> --clear-groups git commit ...
```

The open question is answered: the default ACL survives git chmodding a new
loose object. A written object is `-r--rw-r--+` carrying `user:<role_uid>:rw-`,
git having set the classic bits to 0444 without disturbing the named entry.
Commits by the role uid succeeded repeatedly, as did `status`, `log`, `diff`,
creating a branch in its own namespace, and moving its own ref.

The ref partition holds. `git update-ref refs/heads/master` fails with
`Permission denied` on `refs/heads/master.lock` and the ref does not move;
creating `refs/heads/hotfix` outside the role's namespace fails the same way;
and the role reads every ref in the repository. That a namespaced branch
touches exactly `refs/heads/<role>/` and `logs/refs/heads/<role>/` and nothing
at the top level was measured separately, and is why those two directories are
the ones that carry an ACL.

ADR-004's original failure does not recur. `nix flake metadata` in the role's
worktree resolved the flake and its revision for a uid that owns the worktree
while root owns the common `.git`, which is the case that motivated ADR-004 in
the first place. The uid must have a `passwd` entry for nix to run at all,
which inside a cage it does, since the container maps the role onto uid 0 and
names it.

bats covers the CLI and container seam: a role's uid is stable across runs, a
removed role's uid is not reissued, `enter` passes `--private-users` with the
role's uid rather than the project owner's, and an ordinary project cage still
passes the project owner's.

bats covers the CLI and container seam: a role's uid is stable across runs, a
removed role's uid is not reissued, `enter` passes `--private-users` with the
role's uid rather than the project owner's, and an ordinary project cage still
passes the project owner's.

The decision makes no performance, storage, or capacity claim, so there is no
measurement plan beyond the ACL probe above.
