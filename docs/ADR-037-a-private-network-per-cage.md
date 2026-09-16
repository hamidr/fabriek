---
id: ADR-037
title: A private network per cage, attributed by address, with the budget at the proxy
status: accepted
date: 2026-09-12
status_date: 2026-09-16
summary: each cage has one veth on a per-factory bridge; two bridge rules make attribution proof and the proxy holds the cap
depends_on: [ADR-018, ADR-019, ADR-033]
supersedes: [ADR-025]
superseded_by: []
---

## Context

ADR-025 dropped egress by uid in a network namespace every cage shared, gave
the proxy a uid so the filter could name it, and arranged `resolv.conf` so a
role's resolver failed early. Each was a rule about who may leave a machine
whose network every cage was on. A role denied the network by not having one
is the only kind of denial that cannot be misconfigured.

The budget has to move too. ADR-035 makes loop and agent one uid, so a
self-checked budget is a number the agent can edit. The proxy already sees
every model request and can count.

## Decision

**1. A per-factory internal bridge; each cage gets its own veth and its own
address** and has no other interface. A cage reaches Forgejo, Valkey and the
proxy over that bridge and has no route off the machine. It holds no model
credential, no forge repository credential, no nix daemon socket and no web
access.

**2. Two bridge rules are load-bearing.** The host side drops any packet
whose source is not that cage's assigned address, because spend attribution
is by address and without this a cage can bill a peer. The bridge permits
cage to service and drops cage to cage.

**3. The proxy holds the model credential and injects it at egress,** as
ADR-025 point 1 had it, and counts input and output tokens per source
address and per factory against a ceiling the factory declares and the
operator caps.

**4. Two limits.** At the soft limit the executor stops routing new work and
running turns finish. At a hard limit above it the proxy refuses, so a
runaway cannot outspend the cap with one long turn. This is the only hard
cost control. The count lives in the proxy's memory and starts at zero when
it does: the ceiling bounds a runaway and keeps no account.

**5. Two nixcage interface changes,** each two commits in two repositories
and a lock bump (ADR-018): an `enter` option naming the bridge and the
cage's address, and an option suppressing the nix daemon socket bind. A
third is a removal: `--subject` leaves the line with ADR-028. All three show
up in `tests/command/seam.bats` as a diff.

## Consequences

ADR-025's chain stays for the machine's own processes, of which root and
the proxy may leave, since the executor pushes to origin and the proxy
reaches the model; what leaves it is a role's place in it, because a cage is
on the bridge with no route at all. `models/egress-authority.als` is
deleted with the claim it modelled. `tests/manual/egress.sh` is
replaced by `tests/manual/isolation.sh`, which has to check both bridge
rules and not only egress. A repository qualifies for a factory by being
hermetic: a build that reaches the network does not run in a cage. An agent
has no web access at all, so `modules/role-guidance.md` carries more weight.
ADR-031 becomes literal: a tool reaches a cage through the flake, enforced
by there being no daemon socket.

## Measurement plan

`tests/manual/isolation.sh` on a real machine (docs/roadmap.md 2.4): from a
cage, a connect to any address off the machine fails; a connect to a peer's
address fails; a packet sent with a peer's source address is dropped, shown
by the proxy's count for the peer not moving; a request from the cage moves
its own count and nobody else's. The soft limit stops routing with a running
turn allowed to finish; the hard limit returns a refusal from the proxy.

Status 2026-09-13: `tests/manual/isolation.sh` ran on a machine on
2026-09-12 (docs/roadmap.md 2.4): no route off the machine, no cage to
cage, a spoofed source dropped. The two Thens that read the proxy's count,
and the soft and hard limits, are gated on a credential the endpoint
accepts. The counting filter itself is driven with the API's own bodies
since 2026-09-13 (`modules/guest/spend.test.mjs`).

Status 2026-09-16: `tests/manual/isolation.sh` ran on the appliance
(ADR-057) on a NixOS host with a credential the endpoint accepts. Every
Then passes: the bridge, one address per cage, no route off the machine,
no cage to cage, the proxy answering, one request through it counted for
the sender and for nobody else, a spoofed source dropped, and the
machine's daemon substituting and never fetching. The hard limit's 429
is gated: the example declares 20M tokens and fifty one-token requests
cannot reach it. The proof itself changed to what a cage has, which is
neither `ip` nor `curl`: the address from `/proc/net/fib_trie`, the
requests over bash's `/dev/tcp`, the body read to its end so the filter
sees the usage.
