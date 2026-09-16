---
id: ADR-064
title: The bridge's rules are nixcage's, and fabriek names only the three ports a cage may reach
status: implemented
date: 2026-09-16
status_date: 2026-09-16
summary: attribution and cage-to-cage isolation move to nixcage with the lock bump; bridge.nix keeps the address and the firewall
depends_on: [ADR-018, ADR-037]
supersedes: []
superseded_by: []
---

## Context

ADR-037 point 2 wrote two rules on the bridge: a frame on a cage's port
whose source is not that cage's address is dropped, and a frame from one
cage's port to another is dropped. Point 5 asked nixcage for the placement
option the rules key on, and ADR-013 in nixcage told the caller the veth
name two ways: the `veth <name>` verb `fabriek_render_cage_elements` asks
per cage to fill the set, and `lib.vethHostName`, which `modules/vm.nix`
passes in as a module argument nothing reads.

The rules are correct and they are in the wrong repository. Both are
statements about a placement and nothing about a factory: a bridge with two
cages on it wants them whether or not anything bills by address. Keeping
them here means `bridge.nix` is written in nixcage's dialect, `iifname
"nc-*"` and a set keyed on a hash nixcage chooses, which is the coupling
ADR-018 exists to remove; the verb and the export were made to make the
coupling possible rather than to remove it. A change to the hash upstream
is a set here that matches nothing, and the machine would not say so. And
the set is an element list in a table NixOS declares, which a reload of the
machine's ruleset recreates empty: the pin on a running cage is gone until
the next prepare.

nixcage's ADR-015 takes both rules and the port isolation the kernel
offers, in a table it makes at runtime and no reload touches, and withdraws
the verb and the export. Its ADR-016 gives a private-network cage an empty
resolver by default, which is the slow start ADR-029 point 7 worked around
inside pi, answered at the cage instead. This document is the lock bump
and what it removes here.

## Decision

**1. `flake.lock` moves to a nixcage that carries ADR-015 and ADR-016.**
Two commits in two repositories, as ADR-018 has it.

**2. `bridge.nix` keeps what is the factory's and loses what is not.** It
keeps the bridge, its address, the carrier and bind settings, the
`FABRIEK_*` variables the machine program reads, and the firewall entry
naming the three ports a cage may reach. The `fabriek-cages` table goes
whole: its set, its prerouting chain and its forward chain.

**3. `factory-prepare` fills no set.** `render_machine` loses the flush and
the `nft add element`; `fabriek_render_cage_elements` in
`modules/factory-render.sh` goes with its test. The bridge plan is still
rendered and still read by the executor and the session composer; it no
longer feeds a ruleset.

**4. A role session says nothing about DNS.** The seam line is unchanged:
nixcage's default for a private-network session is the resolver this
factory wants, which is none. `seam.bats` asserts the line is unchanged,
which is the point.

**5. `tests/manual/isolation.sh` stays whole and is nixcage's proof too.**
nixcage has no machine to run one on, and ADR-011, ADR-013 and ADR-015
there each name this script as the dependant's proof. It keeps measuring
both halves: what a cage on the bridge can and cannot reach, which is now
nixcage's promise, and what nixcage cannot know, that a role's spend is
counted under its own address at the proxy, that the forge and the bus
answer on the bridge, and that the model endpoint is reachable through the
proxy and not around it. A failure of the first half is a nixcage bug,
reported upstream with the run.

## Consequences

Removed, in one change with the bump: the `fabriek-cages` table in
`modules/machine/bridge.nix`; `fabriek_render_cage_elements` and its
scenarios in `tests/unit/factory_render.bats`; the `nft flush` and `nft add
element` lines in `render_machine` and the `nft` stub in
`tests/command/render.bats`; the `vethHostName` module argument at
`modules/vm.nix:30`; the `nixcage.lib.vethHostName` row of the interface
table in `CLAUDE.md` and its mention in `docs/architecture.md`. ADR-037
points 2 and 5 are amended by this document and its text says so in place,
as ADR-011 in nixcage was amended.

What the machine loses is a rule its configuration could be read for; what
it gains is a rule tested where the veth is made and one that survives a
reload. The proof that a cage cannot bill a peer is made where the veth is
made and measured here where the machine is, which is the split ADR-011 in
nixcage chose.

## Verification

`tests/command/seam.bats`: the role session's line is unchanged by the bump.
`tests/command/machine_services.bats`: `lib.appliance` evaluates with no
`fabriek-cages` table and with the three ports on the bridge's firewall
entry. `tests/command/render.bats`: prepare runs no `nft`. On a machine,
`tests/manual/isolation.sh` unchanged, and its bridge half passing is
recorded in nixcage ADR-015 as well as here.

Implemented 2026-09-16: `flake.lock` at nixcage `3cdcfe6`, which carries
ADR-015 through ADR-018 there. Removed in the same change: the
`fabriek-cages` table in `modules/machine/bridge.nix`,
`fabriek_render_cage_elements` and its scenario, the `nft` lines in
`render_machine` and the `nft` stub, the `vethHostName` argument in
`modules/vm.nix`, the interface-table row in `CLAUDE.md`.
`tests/command/machine_services.bats` reads the appliance's tables and
finds no `fabriek-cages`; `tests/command/render.bats` runs prepare with no
`nft` on `PATH`; `tests/command/seam.bats` is unchanged and passes. Open:
`tests/manual/isolation.sh` on a machine, recorded here and in nixcage
ADR-015 when run.

Measured 2026-09-16 on a machine built from `1af4e65` with nixcage
`3cdcfe6`: `tests/manual/isolation.sh` against a factory of six roles,
every Then passing and one gated. The bridge is `fabriek0`; a cage sees
`host0` and nothing else besides `lo`; two roles hold `10.77.0.10` and
`10.77.0.11`; no route off the machine and no name resolves; a connection
to the peer's address fails and one to the proxy answers; one request
moves the sender's count and nobody else's; a request forged as the peer's
address from the sender's namespace moves no count; the daemon substitutes
and never fetches. The 429 at the hard limit passed in a run with a
ceiling of 300 tokens and is gated at the example's twenty million. A
ceiling this proof can reach is also one the decider's first turn exceeds
(6273 tokens observed), so the two Thens are proved in two runs, never
one. Recorded in nixcage ADR-015 with the same run.
