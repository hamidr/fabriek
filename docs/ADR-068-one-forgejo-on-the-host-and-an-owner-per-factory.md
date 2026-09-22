---
id: ADR-068
title: One Forgejo on the host, and an owner account per factory
status: proposed
date: 2026-09-22
status_date: 2026-09-22
summary: the board is one instance per host; a factory's repository is owned by a per-factory account that is not an admin
depends_on: [ADR-036, ADR-037, ADR-047, ADR-048, ADR-067]
supersedes: []
superseded_by: []
---

## Context

ADR-067 put every factory's services on the host as instances in the
factory's slice. For the bus that is a Valkey holding a few streams; for
the board it is a whole Forgejo, `modules/host/board.nix`, a template unit
of ours because Forgejo's NixOS module is one instance per host: its own
`app.ini`, its own sqlite database, its own secrets made on first start, its
own repository root, on its own dataset (`fabriek-<name>-record`) at the
factory's bridge address. Forgejo idle is the largest resident cost a
factory has on the host, and the host runs several factories.

What ADR-036 bought from the forge does not depend on the instance being
the factory's. Its authorization matrix is per account and per repository:
a role is a read collaborator with a `write:issue` token on one private
repository, the decider holds `read:issue`, the executor holds the token
of the account that owns the repository. A second private repository in
the same instance is invisible to an account that is not a collaborator
on it.

Two things today do depend on the instance being the factory's. The
owner account `operator` is made `--admin` (`fabriek-container`,
`prepare`), so its token, the executor's, is the whole instance's; that
was harmless with one factory per instance and is not with two. And
prepare makes accounts with `forgejo admin user create`, which opens the
sqlite database beside the running server; two factories' prepares on one
database would race where today each has its own.

## Decision

**1. The board is one Forgejo per host.** `services.fabriek` runs it as
one unit, `fabriek-forge.service`, outside any factory's slice, with one
`app.ini`, one database and one repository root on one dataset asked for
through the storage primitive with the host's `recordQuota`.
`modules/host/board.nix` renders that unit and no longer one per factory;
`fabriek-<name>-record` and `fabriek-<name>-board` are removed. The
`forgejo` wrapper the host installs points at the one work directory and
no longer reads `FABRIEK_STATE`.

**2. A factory's repository is owned by a per-factory account that is not
an admin.** Prepare ensures `<factory>-operator`, an ordinary account, and
the board's repository `<factory>-operator/<factory>`, private, made by
that account with `POST /user/repos`. The executor's token is this
account's, scope `all` on this account, which reaches nothing another
account owns. No organization: an owner account gives the same namespace
and the same collaborator boundary, and nothing here uses teams.

**3. No admin token exists.** What needs the instance's admin, making an
account when registration is off, runs as root through `forgejo admin` on
the host, as now. Everything else prepare does on the forge (repository,
labels, collaborators, pinning a memory issue, restoring the record) is
done as the owner; the measurement below confirms the owner may do all of
it. `factory-board` changes the owner's password through the CLI, as now.

**4. Accounts are named for the factory.** A role's account is
`<factory>-<role>`, the name its cage and its bus user already carry
(`modules/names.sh` bounds the sum); the decider's is
`<factory>-decider`. A role is a read collaborator on its factory's
repository and nothing else, as ADR-036 point 2. Token files stay under
the factory's state as now, keyed by the bare role. ADR-036 points 2
through 9 stand.

**5. Prepare's forge CLI calls take a host-wide lock.** One database, one
writer through the CLI at a time: `fabriek_forge_admin` runs under a flock
on a file beside the forge's state, held per call, so two factories' ups
under their own per-factory locks (ADR-067) do not open the database
together. API calls need no lock; the server serializes them.

**6. The forge listens on every factory's bridge and loopback.**
`HTTP_ADDR` is `0.0.0.0`; the host's firewall opens the forge's port on
`fb-*` and `lo` alone (`modules/host/bridge.nix`), the forward chain of
`modules/host/proxy.nix` still drops anything off a bridge, and an
external interface stays closed as NixOS's firewall leaves it. A cage
reaches the forge at its own bridge's address as now; the facts file does
not change. `ROOT_URL` is the loopback address: nothing in
`factory/src` reads a URL the forge builds, and the operator opening the
board from a bridge address sees links to loopback, which is accepted.

**7. `factory-down` leaves the account and the repository; nothing
deletes them.** Down stops the factory's units and the forge keeps
serving the others; on the next up prepare finds the repository and
changes nothing (ADR-036's idempotence). ADR-047's verbs have no remove,
and this document adds none: a factory taken out of
`services.fabriek.factories` leaves its owner, its role accounts and its
repository on the forge until the operator deletes them in the UI, after
`mirror` has copied the record out. A later ADR may add the verb.

**8. `recordQuota` bounds the host's dataset, not a factory.**
The declaration's `resources.recordQuota` and its clamp
(`modules/repo-declaration.sh`, `modules/machine-spec.sh`,
`modules/resources.sh`, `render_machine`) are removed with the per-factory
dataset: a key that is accepted and does nothing is worse than one
refused. A per-factory bound inside Forgejo (its quota rules) needs an
admin token to assign, which point 3 refuses; if a per-factory bound is
wanted later, that is its own decision.

## Consequences

One Forgejo resident per host instead of one per factory; a factory's
cost on the host is its Valkey, its executor and its cages. `board.nix`
shrinks to one unit and one settings block; `bus.nix`, the bridge and the
proxy are untouched.

Two factories share the forge's fate: a restart, an upgrade or a full
dataset touches both. The forge is no longer in any factory's slice, so
its CPU and memory are the host's in the probes' accounting, not a
factory's (the `forgejo` uid was already one for every instance). An
operator who wants a factory's board isolated by kernel does not get it
from this; that is a second host.

The executor's credential narrows: from an instance admin's to an
owner's. That is a change ADR-067's single-factory instance did not need
and this one does. Any token in the instance may search accounts and
learn that `b-operator` and `b-dev` exist; names are not secrets here.
Two factories worked from the same origin are `a-operator/a` and
`b-operator/b`.

A declaration carrying `resources.recordQuota` is refused after this
lands; the example and the schema drop it. `tests/system/journey.sh`
names the owner `<factory>-operator` instead of `operator`.

ADR-036's point 1 is amended (the board is on the host's dataset, not the
factory's) and ADR-067's `-record` and `-board` units are gone; both
documents note it in their status.

## Measurement

Each gate runs against the Forgejo the host pins, on a NixOS host with two
factories declared, and is recorded in this document's status before it
moves to accepted.

1. Owner without admin. As `a-operator` (not an admin), with the
   `write:issue` token of `a-dev`: create the repository, the labels,
   add `a-dev` as reader, open the memory issue as `a-dev`, label and pin
   it as the owner, restore a record of three issues. Every call 2xx.
   As `a-operator`: `GET /api/v1/admin/users` is 403.
2. Collaborator boundary across owners. With `a-dev` a read collaborator
   on `a-operator/a` and `b-operator/b` private, as `a-dev`'s
   `write:issue` token: `GET /api/v1/repos/b-operator/b` is 404, `GET
   /api/v1/repos/b-operator/b/issues` is 404, `POST
   /api/v1/repos/b-operator/b/issues/1/comments` is 404, `GET
   /api/v1/user/repos` lists `a-operator/a` alone. As `a-operator`'s
   token: `GET /api/v1/repos/b-operator/b` is 404. The twenty results of
   decision 52 hold on `a-operator/a`.
3. Concurrent up. `fabriek up a & fabriek up b; wait` ten times from
   empty state: both prepared, no `database is locked` in either
   journal, and `forgejo admin user list` shows every account once.
4. Memory. `systemctl show -p MemoryCurrent fabriek-forge.service` idle
   with two factories prepared, against the sum of the two
   `fabriek-<name>-board.service` values on the commit before; the
   number is recorded, not promised.
5. Down and up. `fabriek down a`; `b`'s executor keeps running; `fabriek
   up a` finds `a`'s board with every issue and label it had
   (`tests/manual/stop-and-start.sh`).
6. The seam. `tests/command/seam.bats` unchanged: no enter line moves.
