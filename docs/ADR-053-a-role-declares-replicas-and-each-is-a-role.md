---
id: ADR-053
title: A role declares replicas, and each replica is a role in everything but its declaration
status: proposed
date: 2026-09-15
status_date: 2026-09-15
summary: replicas = N expands one declared role into N named roles before anything reads the declaration; nothing else changes
depends_on: [ADR-010, ADR-020, ADR-033, ADR-034, ADR-036, ADR-037]
supersedes: []
superseded_by: []
---

## Context

A role works one task at a time: the executor refuses a second
assignment while one is `assigning` or `assigned` (`core.ts`, `holds`),
because a role has one worktree and one branch, `<role>/work`
(ADR-010). Capacity at a stage is the number of roles providing its
capability, which ADR-015 point 7 stated and ADR-034 point 7 kept when
it gave the choice among them to the decider. To double the builders an
operator copies the role's block under a second name.

That copy is the whole mechanism today, and it is right about one
thing: nothing that makes a role a role can be shared. A replica needs
its own uid and cage (ADR-037), its own worktree and dataset (ADR-010),
its own refs namespace, its own signing key and forge account so the
record says who (ADR-033), its own bus user and streams, its own memory
issue (ADR-036 point 3; two writers of one memory is ADR-024's double
account). A pool of replicas over one worktree, or one task split across
replicas, is not a design this system can hold, and neither is wanted:
the unit of work is one issue, one role, one branch.

What is wrong with the copy is only that it is a copy. `provides`,
`specialists` and `shell` are repeated, a change to one is missed on
the other, and `consults` has to name each. Two numbers already in the
declaration touch this: `resources.concurrency` divides the machine's
memory and cores per cage (`machine-plan.sh`) and says nothing about
how many cages there are; a stage's `fanout` is in the schema and read
by nothing.

## Decision

**1. A role may declare `replicas = N`.** An integer of at least 2; 1
is the default and is refused when written, because a replica count of
one is a copy of nothing.

**2. Expansion is the first thing the declaration undergoes, and it
happens once.** `repo-declaration.sh` expands a role with `replicas = N`
into `<name>-1` ... `<name>-N`, each carrying the base role's
`provides`, `specialists`, `shell` and `command`, and drops the base
name; the `declaration.json` the build writes to the machine holds the
expanded roles and no `replicas` key. `declaration.ts` keeps its rule
of refusing only what the table could not have produced, so a
`replicas` key reaching it is refused by name. Everything that reads
the declaration afterwards, the forge accounts and tokens, the bus
users and ACL, the cages and their addresses, the profiles and pi
directories, the probes' uid table, the executor, the decider, the
trace, `ps`, sees N roles and changes nothing. The decider spreads
work among them by the rule it has.

**3. A replica's name is checked like any role's.** `<name>-N` must
pass `fabriek_role_name_ok`, so a base name near the sixty-four
character limit with many replicas is refused naming the first that
does not fit. A role declared by hand whose name is `<base>-<digits>`
beside a `<base>` with replicas is refused as a collision, naming both.
The bridge is a /24 handing cages `.10` upward (`bridge.nix`), so an
expanded declaration of more than 244 roles is refused at the schema
naming the ceiling, rather than planning an address that does not
exist.

**4. `consults` and `provides` name the base.** A `consults.backend`
expands to every `backend-N` on the asking side, and a role named in
a `consults` list expands to every replica of it on the answering
side, so the key stays well-formed after expansion. Nothing reads
`consults` today: `declaration.ts` parses it and no executor, decider
or actor code consumes it. The expansion is schema hygiene, not a
promise that a consult reaches a replica. `provides` needs nothing:
each replica provides what the base did. A stage's `ready`, `done` and
`gate` name no role.

**5. A declared `concurrency` is checked against the expanded roles.**
`resources.concurrency` is what `machine-plan.sh` divides memory and
cores by, with a default of 1 when absent, which today gives every cage
the whole allowance. When the key is declared and smaller than the
expanded role count, `check` refuses naming both numbers, rather than
sizing each cage for fewer roles than there are. When it is absent
nothing changes: whether an absent `concurrency` should mean the role
count is a correction to sizing for every declaration, replicas or
not, and belongs in a record of its own; `docs/roadmap.md` carries it.

**6. The memory issue is per replica.** ADR-036 point 3 stands: one
pinned issue per role, opened as the role. Replicas do not share one;
what one learned the manager (ADR-050) reads across all of them, and
`docs/factory-guidance.md` is where a lesson every replica should hold
goes.

**7. `fanout` leaves the schema.** Nothing reads it and ADR-015 called
it decorative; a stage's parallelism is the number of roles providing
its capability, which this record makes cheap to raise.

## Consequences

`replicas = 3` on `backend` is three cages, three worktrees, three
keys, three accounts, three lines in `fabriek ps`, and one block in
`fabriek.nix`. The cost of a replica is the cost of a role, paid at
`up` and in the machine's memory, and the record names `backend-2` as
the author of what `backend-2` did.

Every consumer of role names that a person reads (`ps`, the console,
`show -f`, the trace) shows the expanded names. Grouping them under the
base is a presentation the TUI may add; nothing depends on it.

The expansion is one pure jq function in the shell validator, and its
property is that expanded names collide with no declared name and with
each other never; a property test over generated declarations is
enough, and a model would be heavier than the code. Nix sorts attribute
names, so `backend-10` sits before `backend-2` in addresses and
listings; names are names and none is padded.

Three replicas build three specialist profiles differing only in the
role name inside their error strings. Build time, not correctness; a
later change may compose one per base and link the rest.

A base role's name is no longer a role: `fabriek enter backend` on a
replicated role is refused naming `backend-1` to `backend-3`, and a
`steer` names a replica.

Nothing here makes a task parallel. A stage that files three tasks
runs on three replicas at once and on one replica in sequence; that
is the whole of it.

## Verification

```bash
nix develop --command bats tests/unit/repo_declaration.bats
nix develop --command bash -c 'cd factory && node --test dist/declaration.test.js'
nix develop --command bats tests/command/check.bats tests/command/machine_services.bats
docmeta-check docs && docmeta-tracker --check docs
```

`repo_declaration.bats` expands `replicas = 3` to three named roles
and drops the base; refuses `replicas = 1`, a non-integer, a name that
would not fit, a hand-declared `backend-2` beside it, more than 244
roles, and a declared `concurrency` below the expanded count; expands
`consults` both ways; and, over generated declarations, finds no
expanded name equal to a declared one. `declaration.test.ts` refuses a
`replicas` key. `machine_services.bats` reads three profiles and three
cage addresses out of a machine built from a replicated declaration.
