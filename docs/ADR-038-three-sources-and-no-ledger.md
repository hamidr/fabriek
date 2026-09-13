---
id: ADR-038
title: A factory is observed from three sources, and nothing writes a ledger
status: accepted
date: 2026-09-12
status_date: 2026-09-12
summary: the thread is what a role said, the proxy what it spent, the probes what it ran; events go to the bus, unpersisted
depends_on: [ADR-033, ADR-036, ADR-037]
supersedes: [ADR-027]
superseded_by: []
---

## Context

ADR-027 built a ledger: journald stamping `_UID` off `SO_PEERCRED`, a
namespace per factory with a quota, a tap in the loop, and DuckDB over an
NDJSON export. Its first source depended on the loop being a different uid
from the agent (ADR-028), and ADR-035 spends that. A ledger the agent's uid
writes is not evidence, and a ledger nobody reads is a dataset that fills.

## Decision

**1. Three sources, never merged.** The Forgejo thread is what a role said it
did, under a token Forgejo refuses to let another role use. The proxy is what
it spent, attributed by address. The kernel probes are what it ran.

**2. Nothing persists the event stream.** The extension publishes turn and
tool events to the bus, because that is what the operator watches live, and
nothing writes them down. pi's own session directory holds the verbatim
transcript on the role's own storage.

**3. The kernel probes publish to a capped `probes` stream on the bus,**
keyed by uid, written by the machine and by no role. `sched_process_exec`,
`sched_process_exit` and socket connect, as before; the sink changes, not
the probes.

**4. The proxy logs metadata and never a header or a body,** to journald on
the machine as ADR-027 point 10 had it; whether that log joins the bus is
decided when the proxy is built (docs/roadmap.md 2.2).

## Consequences

The tap, the bus consumer, the per-factory journal namespace,
`resources.journalQuota`, `modules/journal.sh` and `models/ledger-tap.qnt`
are deleted; the dataset's slot in `modules/resources.sh` becomes
`recordQuota` for Forgejo (ADR-036). The first source is stronger in that
Forgejo refuses a role writing as another, and weaker in that a token which
can comment can edit its own comments; the thread's edit history is the
audit. The `probes` stream's cap is a number chosen in 2.2 and stated there.

## Verification

Extension scenarios (docs/roadmap.md 3.2): every turn and tool event reaches
the bus and no file under the role's home grows with them. Machine scenarios
(2.2): a process started in a cage appears on `probes` with that cage's uid
and the stream length never exceeds its cap.

Status 2026-09-13: turn and tool events reach the bus as events
(`factory/src/extension/actor.test.ts`), and since 2026-09-13 each probe
entry carries the role its uid belongs to (`tests/command/probes.bats`).
Not yet seen on a machine: a process started in a cage appearing on
`probes`, and the cap holding; that is what keeps this at accepted.
