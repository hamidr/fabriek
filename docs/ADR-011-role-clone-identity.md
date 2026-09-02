---
id: ADR-011
title: A factory role owns a clone on nixcage's own storage, not a worktree of the operator's repository
status: proposed
date: 2026-09-02
status_date: 2026-09-02
summary: roles work in per-role clones on a Linux filesystem and the supervisor moves commits to and from the operator's checkout
depends_on: [ADR-004, ADR-009]
supersedes: [ADR-010]
superseded_by: []
---

## Context

ADR-010 gave each factory role its own uid, handed it a worktree of the
factory's repository, and granted that uid the object database and its own ref
directories through POSIX ACLs. Every part of it was measured working, and all
of it was measured on the VM's own ext volume.

It cannot work where a macOS factory's repository would actually live. The
operator's workspace roots reach the VM over 9p, and there:

```
setfacl: Operation not supported
chown:   Operation not permitted
```

virtiofs is not an alternative, because virtiofsd does not exist on a macOS
host, which is why the module defaults to 9p. Nor is the 9p `mapped` security
model a repair: it stores ownership as xattrs and would make `chown` work,
while POSIX ACLs live in a namespace 9p's mapped metadata does not carry, so
the shared object database would still have no way to admit several role uids.

The problem is not the protocol. It is that the backing store is APFS, where a
Linux uid means nothing and the ACL model is a different one. Any design that
requires the operator's own checkout to carry Linux ownership fails on macOS
for reasons no amount of mount options will fix.

What the design actually needs is narrower than what ADR-010 built: a role
needs a tree it owns on a filesystem that supports ownership. It does not need
that tree to be the operator's checkout.

## Decision

A role works in a clone of its own, on nixcage's storage, and the supervisor
moves commits between that clone and the operator's checkout.

**1. A uid per role, from a declared range.** Unchanged from ADR-010. The
declaration names a base and a size, a role is assigned the lowest free uid on
first use and keeps it, a removed role's uid is never reissued, and the cage
runs with `--private-users=<role_uid>:1`.

**2. A name inside the cage.** Unchanged. The session skeleton's `/etc/passwd`
names uid 0 as the role, so the prompt and anything resolving the uid say which
role is running.

**3. A clone per role, on nixcage's own storage.** Each role's clone lives
under the state directory, which is a real Linux filesystem on both platforms,
is made with `--no-hardlinks`, and is chowned to the role's uid in its
entirety. The flag is not an optimisation choice: git hardlinks objects when it
clones from a local path on the same filesystem, and chowning a clone whose
objects are hardlinks rewrites the ownership of the origin's objects too. That
is measured, not feared, and it would corrupt the operator's own repository on
Linux where both sit on one filesystem. Ownership is then ordinary
and total: no ACL, no shared object database, no partitioned refs, and no
dependence on any property of the operator's filesystem.

**4. The supervisor moves commits.** Roles never touch the operator's
checkout. The supervisor fetches from it into a role's clone before a run, and
pushes a role's branch back to it afterwards. It already runs outside every
cage and already performs the one irreversible act, so this adds no authority
it did not have.

**5. `main` stays unwritable by a role, by ownership alone.** A role's clone is
its own, so what it does there is its business; the operator's checkout belongs
to the operator, and a role holds no credential and no write access to it. What
ADR-010 achieved with a ref partition and an ACL, this achieves by the role
simply not being able to reach the repository that matters.

**6. Branches stay namespaced.** A role's branches are `<role>/<name>`. The
partition is no longer a permission boundary, since a role's clone is entirely
its own, but it keeps two roles' branches from colliding when the supervisor
pushes them into one repository.

**7. Home, skeleton, and signing key follow the role.** Unchanged from ADR-010,
including ADR-009's key being 0400 owned by the role's uid.

## Consequences

The mechanism no longer depends on any property of the operator's filesystem,
so a factory works the same on Linux and on macOS. That is the point, and it is
worth more than the elegance it costs.

It costs a full copy per role in disk, and the copy is mandatory rather than
lazy. Git's two ways of making a local clone cheap are both unavailable: an
alternates file puts every role back on one object database, which is the thing
that needed ACLs, and hardlinked objects make one role's chown reach into every
other clone and into the origin. A filesystem with copy-on-write clones would
give the cheapness back without either hazard, and is worth revisiting only if
the disk cost is felt, since it would make the mechanism depend on the
operator's filesystem again.

Integration becomes fetch and push rather than a local ref update. The
supervisor still advances the operator's `main` by fast-forward and still
refuses anything else, so the property that a bad merge is recoverable is
unchanged. What changes is that a role's work is not visible in the operator's
repository until the supervisor pushes it, where before it was there as soon as
the role committed.

A role cannot see another role's work directly. Everything moves through the
supervisor, which is more traffic and one more thing to get right, and also
means a confused role cannot read a neighbour's branch by accident.

ADR-010's ACL machinery is removed rather than left in place. It was measured
working and it is genuinely more elegant, but a mechanism that cannot run on
the machine the operator uses is not the mechanism, and keeping both would mean
two ownership models diverging by platform.

The `acl` runtime dependency goes with it.

## Verification

The failure that prompted this was measured in the VM: on the 9p workspace
mount, `setfacl` reports `Operation not supported` and `chown` reports
`Operation not permitted`, while both succeed on `/var/lib/nixcage`.

Measured in the VM, with the operator's checkout on the 9p share and the role's
clone on `/var/lib/nixcage`:

```
git clone --no-hardlinks <operator-repo> <clone>; chown -R <role_uid> <clone>
setpriv --reuid=<role_uid> ... git -C <clone> commit    # succeeds, no ACL anywhere
git -c safe.directory=<clone> -C <clone> push <operator-repo> <role>/work
```

The push lands: `refs/heads/builder/work` appears in the operator's checkout on
the share and resolves to the commit the role made. Fetching the other way
works too, so either direction is available to the supervisor.

A default local clone on one filesystem shares object inodes with its origin:
link count 2, same inode, and `chown -R` on the clone moved the origin's object
from uid 0 to 700000. With `--no-hardlinks` the inodes differ and chowning one
clone leaves the origin alone.

Two more things came out of measuring. The supervisor is root and the clone belongs
to the role, so git's ownership check refuses to run there until the supervisor
names the clone in `safe.directory`; without it the push fails with `detected
dubious ownership` rather than a permission error. And git refuses to move a
branch that is checked out somewhere: fetching into the operator's current
branch failed with `refusing to fetch into branch ... checked out at ...`. That
is not an obstacle but a second reason for a rule PRD-003 already has, that the
branch the factory advances is checked out by nothing.

What ADR-010 measured and this decision keeps: a foreign uid can commit to a
repository it owns on an ext filesystem, and `nix flake metadata` resolves a
flake in a tree owned by that uid.

bats covers the seam as before: a role's uid is stable, a removed role's uid is
not reissued, a clone is created once and reused, and an ordinary project cage
still maps onto the project owner.
