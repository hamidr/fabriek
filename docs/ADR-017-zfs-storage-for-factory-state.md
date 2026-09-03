---
id: ADR-017
title: The VM keeps nixcage's state on ZFS, one dataset per role worktree
status: implemented
date: 2026-09-03
status_date: 2026-09-03
summary: factory state moves to a ZFS pool with a dataset and quota per role worktree; worktrees stay, clones are refused
depends_on: [ADR-010, ADR-011]
supersedes: []
superseded_by: []
---

## Context

Two things went wrong on ext4, and one of them destroyed work.

The VM is stopped by sending SIGTERM to qemu, which ends the process without
the guest ever shutting down. ext4 delays allocation, so files written in the
seconds before that are left with committed metadata and no data: zero bytes,
full size. In one session this produced a role worktree whose every file was
empty, a `flake.lock` of zero bytes, a zero-length `refs/heads/owner/work` that
made git refuse to open the repository at all, and a truncated nix eval-cache
database. Each needed manual repair. This is not a rare interaction; it is what
that filesystem does when the machine disappears.

The second is quieter. A role writes into its worktree with no bound, so one
agent in a build loop fills the volume and every other role and the supervisor
stop with it. Nothing in the design says how much a role may write, because on
ext4 there is nowhere to say it.

The operator proposed a copy-on-write filesystem, with the repository cloned
once and each role given a CoW copy to work in. The filesystem half of that is
right. The clone-per-role half was examined and is not adopted, for reasons
recorded below.

## Decision

**1. The VM keeps its state on a ZFS pool of its own.** A volume is attached
unmounted and the pool is created on it at first boot, or imported on every
boot after. `/var/lib/nixcage` is a dataset on it: the factory clones, every
role worktree, every session home, the tasks and the age identity.

**2. A role's worktree is a dataset of its own,** created when the role's
worktree is prepared and named after the same path. That is what makes the
third point possible.

**3. A role may be given a quota.** `nixcage.supervisor.roleQuota` sets
`refquota` on each role's dataset, so one agent cannot take the volume from the
others. It is applied on every preparation rather than at creation, so changing
the declaration binds roles that already exist, and clearing it releases them.

**4. `acltype=posixacl` and `xattr=sa` are set on the pool, and they are not
tuning.** A role reaches the repository's object database through a POSIX ACL
(ADR-010). ZFS refuses `setfacl` without them, so the factory would not work at
all.

**5. Worktrees stay; a clone per role is refused.** Isolation is already had:
a role has its own uid, owns its worktree, and may write only its own refs.
Clones would replace that with a mechanism that costs more -- every integration
becomes a fetch instead of a local ref update, and objects stop being shared by
git. They buy no parallelism either, since a role still has one working
directory and still takes one task at a time.

The one thing a clone would buy is coherent snapshot rollback, because the unit
rolled back has to contain the working files, the index, HEAD and the refs. A
worktree's index and HEAD live in the factory clone's git directory, on another
dataset, so rolling a worktree back would revert the files and leave git's idea
of them behind. No rollback is therefore offered, and none is implied by having
snapshots available. If per-attempt rollback is ever wanted, this is the
decision to reopen, and clone-per-role is the shape it takes.

**6. On a Linux host, ZFS is used when the admin has it and never required.**
`nixcage.storage.dataset` names the dataset holding nixcage's state, and unset
means ordinary directories and today's behaviour exactly. Requiring a
filesystem of a machine nixcage does not own is not ours to do, and because
worktrees are kept, the semantics do not change either way: what is lost
without ZFS is durability under an unclean stop and the per-role quota, not
correctness. That degradation is only tolerable because the mechanism is the
same on both sides. It would not have been with clones, which would have needed
a second mechanism for hosts without ZFS.

**7. State on the old ext4 volume is migrated once.** The volume stays attached
at `/var/lib/nixcage.legacy` and its contents are copied into the empty pool on
the first boot that finds both. Without this a rebuild would silently strand
every role's home, the factory clones, and the age identity the operator's
secrets are encrypted to. `nixcage.vm.legacyDataVolume` turns the old volume off
once the copy has happened.

## Consequences

The guest kernel is pinned to a release ZFS supports, rather than the newest
one. ZFS tracks kernel releases from behind, and a VM that fails to build is
worse than a VM one release back.

The ARC is capped, because the VM's memory belongs to the builds and agents it
exists to run rather than to a cache in front of a file on the host's disk.

There are two volumes holding state until the legacy one is turned off, and the
pool image is created by microvm.nix with a filesystem on it that `zpool
create` immediately overwrites. microvm.nix makes a filesystem on every volume
it creates and has no `mkfs.zfs`; taking the device over is cheaper than
teaching the host CLI to create images.

A pool that exists and will not import is a fault, and the storage service says
so and stops rather than creating a new one. Recreating would take every role's
state with it, and an unimportable pool is a thing to look at, never a device to
reformat.

Compression is on, which is close to free on source trees and build output and
is the cheapest part of this.

The writable Nix store overlay stays on ext4 and is exposed to the same
truncation, which is accepted rather than overlooked: it is an overlayfs upper
directory, and putting one on ZFS is a combination with a history of its own.
The consequence is bounded in a way the state's was not, since a store path can
be checked (`nix-store --verify --check-contents`) and rebuilt, while a role's
worktree could only be repaired by hand.

Snapshots are available and nothing takes them. That is deliberate: see point 5.

## Verification

Driven on a VM built from the shipped configuration template, carrying state
written before the change.

The pool is created on first boot and `/var/lib/nixcage` is `nixcage/state`.
The migration ran once and said what it moved: the age identity, the SSH host
key, the factory clones, the role worktrees, the homes and the uid map. The
host key surviving is why the operator's `known_hosts` still matched
afterwards, which is the sharpest evidence the copy was faithful.

The ACLs ADR-010 grants are on the pool: `getfacl` on the clone's object
directory lists `user:700000:rwx` through `user:700003:rwx`, one per role. ZFS
refuses these without `acltype=posixacl`, so this is the property that would
have made the factory stop working.

A role declared after the change has its own dataset, mounted at its worktree
path and carrying `refquota=1G`. The datasets above it are mounted nowhere.
With a quota of 1G, writing 1200 MiB into that role's worktree stopped at
1023 MiB, and another role wrote to its own worktree while the first was full.

Roles migrated off the old volume keep their directories and say so, rather
than getting a dataset mounted over work that is already there.

That last property was not designed in advance. An earlier build of this change
created a role's dataset with `zfs create -p`, whose intermediate datasets
inherit a mountpoint and therefore mount: the parent covered
`/var/lib/nixcage/worktrees`, and every migrated worktree vanished from view
while remaining on disk underneath. It was found by running it. The datasets
above a role are now created explicitly with `mountpoint=none`, and a worktree
directory that already has contents is left alone.

The failure that prompted all of this: 300 files were written into the pool and
qemu was killed with SIGKILL a second later, inside the window ZFS has not yet
committed. After the restart the directory was absent entirely -- rolled back
to the last consistent transaction group -- no file in the state was
zero-length, the pool reported healthy, and everything written before it was
intact. Absent is a state a retry handles. The ext4 failure this replaces left
files that existed, carried their full size, and contained nothing, which took
manual repair each time.
