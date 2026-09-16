---
id: ADR-064
title: The bridge's rules are nixcage's, and fabriek names only the three ports a cage may reach
status: proposed
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
option the rules key on, and ADR-013 in nixcage exported `lib.vethHostName`
so `modules/machine/bridge.nix` could fill its set from the plan
`factory-prepare` renders.

The rules are correct and they are in the wrong repository. Both are
statements about a placement and nothing about a factory: a bridge with two
cages on it wants them whether or not anything bills by address. Keeping
them here means `bridge.nix` is written in nixcage's dialect, `iifname
"nc-*"` and a set keyed on a hash nixcage chooses, which is the coupling
ADR-018 exists to remove; `lib.vethHostName` was exported to make the
coupling possible rather than to remove it. A change to the hash upstream
is a set here that matches nothing, and the machine would not say so.

nixcage's ADR-015 takes both rules and the port isolation the kernel
offers, and withdraws the export. Its ADR-016 gives a bridged cage an empty
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
nixcage's default for a bridged placement is the resolver this factory
wants, which is none. `seam.bats` asserts the line is unchanged, which is
the point.

**5. `tests/manual/isolation.sh` keeps the factory's half.** The measurement
of what a cage on the bridge can and cannot reach moves to nixcage with the
rules; what stays here is what nixcage cannot know: that a role's spend is
counted under its own address at the proxy, that the forge and the bus
answer on the bridge, and that the model endpoint is reachable through the
proxy and not around it.

## Consequences

Removed, in one change with the bump: the `fabriek-cages` table in
`modules/machine/bridge.nix`; `fabriek_render_cage_elements` and its
scenarios in `tests/unit/factory_render.bats`; the `nft flush` and `nft add
element` lines and the `nft` stub in `tests/command/render.bats`; every
mention of `nixcage.lib.vethHostName` in `CLAUDE.md`,
`docs/architecture.md` and the interface table; the bridge half of
`tests/manual/isolation.sh`. ADR-037 points 2 and 5 are amended by this
document and its text says so in place, as ADR-011 in nixcage was amended.

What the machine loses is a rule it could read; what it gains is a rule
tested where the veth is made. The proof that a cage cannot bill a peer
moves out of this repository and into the one whose lock pins it, which is
where a dependant should want it.

## Verification

`tests/command/seam.bats`: the role session's line is unchanged by the bump.
`tests/command/machine_services.bats`: `lib.appliance` evaluates with no
`fabriek-cages` table and with the three ports on the bridge's firewall
entry. `tests/command/render.bats`: prepare runs no `nft`. On a machine,
`tests/manual/isolation.sh` as amended by point 5, after nixcage's own
has passed on the same machine.
