---
id: ADR-011
title: A factory works a clone on nixcage's own storage, synced with the operator's checkout
status: proposed
date: 2026-09-02
status_date: 2026-09-02
summary: a factory works a clone on nixcage storage that the supervisor syncs with the operator's checkout
depends_on: [ADR-010]
supersedes: []
superseded_by: []
---

## Context

ADR-010 hands each role a worktree it owns and grants its uid the object
database and its own ref directories by ACL. It requires a filesystem that
carries ownership and POSIX ACLs, and it never said which repository that
filesystem holds.

That turns out to be the whole question on macOS. The operator's workspace
roots reach the VM over 9p, and there:

```
setfacl: Operation not supported
chown:   Operation not permitted
```

Three ways out were measured rather than argued. virtiofs is unavailable,
because virtiofsd does not exist on a macOS host. The 9p `mapped` security
model was built into a probe share and booted: `chown` succeeds on it and
`setfacl` still reports `Operation not supported`, so it fixes ownership and
not the half that blocks. And a clone per role works but pays for it, since git
hardlinks objects from a local origin and chowning such a clone rewrites the
origin's ownership, so every clone must be a full copy.

The mistake was assuming the repository a factory works has to be the one the
operator edits. It does not. ADR-010's mechanism was never broken; it was being
pointed at the wrong filesystem.

## Decision

A factory works a clone of the assigned repository, held on nixcage's own
storage, and the supervisor syncs that clone with the operator's checkout.

**1. One clone per factory, not per role.** It lives under the state
directory, which is a real Linux filesystem on both platforms. Roles take
worktrees of it exactly as ADR-010 describes, so there is one copy of the
object database rather than one per role.

**2. ADR-010 applies unchanged, one layer in.** The role's worktree and its
administrative directory are chowned to the role's uid, and ACLs grant that uid
`objects`, `refs/heads/<role>` and `logs/refs/heads/<role>` of the factory
clone. Every one of those operations is on a filesystem that supports them.

**3. The supervisor owns both directions.** It fetches the operator's checkout
into the factory clone, and pushes role branches back out to it. Roles never
touch the operator's checkout and hold no credential that would let them.

**4. The operator's checkout stays exactly what it is.** An ordinary git
repository on their own machine, on their own filesystem, edited with their own
tools. Nothing about it has to carry a Linux uid or an ACL, which is what makes
the whole design portable.

**5. The clone is not the operator's to edit.** It is the supervisor's working
copy. Everything that reaches it arrives by fetch and everything that leaves it
leaves by push, so a human editing it directly is outside the design rather
than served by it.

## Consequences

The factory works the same on Linux and macOS, because nothing it needs is
asked of the operator's filesystem. That is the point of the decision.

Roles keep what clone-per-role would have cost them. One shared object
database means one copy of the history rather than N, and a role can read
another role's branch, which matters as soon as a reviewer has to look at what
a builder did.

There is one more hop than before: the operator's checkout, the factory clone,
and the role worktrees. Two sync points instead of one, and a role's work is
not visible to the operator until the supervisor pushes it. That delay is not
new; it is the same one integration already had.

The factory clone is state that can drift. If the operator rewrites history in
their checkout, the clone has to be reconciled rather than assumed, and nothing
here says how. Recorded as an open question rather than pretended away.

`--no-hardlinks` still matters when the factory clone is made, for the same
reason it mattered for role clones: the origin may be on the same filesystem,
and chowning a clone with hardlinked objects rewrites the origin's ownership.
That was measured, uid 0 became 700000 in the origin, and on Linux the
operator's own repository is exactly what sits there.

## Verification

Measured in the VM, with the operator's checkout on the 9p share and the
factory clone on `/var/lib/nixcage`:

- One clone is made on ext, and two role worktrees are taken from it, each
  chowned to its own uid with ACLs on the clone's `objects` and the role's own
  ref and reflog directories.
- Both roles commit into that shared object database with no shared group
  anywhere: `builder` and `reviewer` each produced a commit.
- A role reads the other's branch: `builder` resolved `reviewer/work`.
- A role cannot move a branch outside its namespace: updating
  `refs/heads/operator/work` fails with `Permission denied` on the ref lock.
- The supervisor pushes a role branch from the clone onto the operator's
  checkout across 9p, and `refs/heads/builder/work` appears there.

Separately measured, and the reason this decision exists: on the 9p share
`chown` and `setfacl` both fail, on a `mapped` 9p share `chown` succeeds and
`setfacl` still fails, and a default local clone shares object inodes with its
origin so that chowning it rewrites the origin's ownership.

Still to measure: what the supervisor does when the operator's checkout and the
factory clone have diverged, which is the open question above.

bats covers the seam: the factory clone is created once and reused, a role's
worktree is taken from the clone rather than from the operator's repository,
and an ordinary project cage is untouched by any of it.
