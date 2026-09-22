---
id: ADR-039
title: The operator's client is a TUI on a relay, and fabriek is the machine
status: implemented
date: 2026-09-12
status_date: 2026-09-13
summary: a TUI on the operator host reads a JSONL relay and writes through the CLI; the host holds a launcher and no decision
depends_on: [ADR-019, ADR-034, ADR-035, ADR-036]
supersedes: [ADR-026]
superseded_by: []
---

## Context

ADR-026 made the loop the console, one unix socket per role, and refused to
own a client. With the loop inside pi (ADR-035) and the bus carrying every
event (ADR-038), the socket per role is gone and the question of the client
returns. Forgejo's web UI shows the board and the pull requests; it does not
show what is happening right now, and it is not a place to speak into a
running turn.

## Decision

**1. The operator reads the bus and writes through the executor.** Watching
survives a dead executor; every intervention is recorded; stopping works
over ssh without the executor.

**2. `fabriek factory watch <factory>` is the relay:** the bus as JSONL on
stdout over the machine's ssh port, its shape written down and covered by a
contract test on each side. It is what our client consumes and what anyone
building another client consumes, so ADR-026 point 7 survives as an option
beside ours.

**3. The client is a TUI of ours, on the operator's host,** consuming the
relay and writing through the `fabriek` CLI. It is the one face: roles and
their state, the board by stage label, the live stream per role, steer and
abort, file, block, retry, stop, mirror, each role's memory issue, the open
pull requests, and spend per role and for the decider against the ceiling.
Forgejo's web UI over the forwarded port stays reachable and is required for
the merge click alone (ADR-036 point 6).

**4. fabriek is the machine; the host holds a launcher and a client.** On
the operator's host: `up`, `down`, `vm status`, `factory mirror`, `factory
watch`, `task file`, `role stop`, the TUI, and `config.toml` with its
ceilings and credential paths. Everything else lives on the machine, and a
new capability is added there first.

**5. herdr and `--pane` leave** with `modules/task-store.sh` and the verbs
they served.

## Consequences

The relay is a second interface after nixcage's three primitives, and the
suite asserts on it. Node is in the operator's flake. A console on the host
does not die with an ssh session, which was the reason the in-guest
alternative lost. The CLI shrinks to the launcher and loses `task list`,
`task show`, `task thread`, `task answer`, `factory sync`, `factory
integrate`, `factory resume`, `factory reports` and `factory status`; their
work is the TUI's, over the relay and the board.

## Verification

Relay contract tests (docs/roadmap.md 3.5): every message shape the bus
carries has a fixture, the guest side emits it and the host side parses it.
TUI scenarios (4.2): every verb the executor accepts is reachable from the
TUI, and a session that reconnects after a dropped ssh shows the board and
the stream without a blank screen.

Implemented 2026-09-13: `relay/fixtures.json` is read by the relay's test
and the TUI's; every verb the executor accepts is a key in `tui/main.ts`;
and since 2026-09-13 the relay reads on from the last id after the bus
goes away (`relay/tail.ts`), the TUI starts a watch again when it ends and
opens on what the bus still holds (`tui/watch.ts`), which is the reconnect
scenario above, on fakes.

Status 2026-09-22: ADR-069 is implemented, and point 2's relay reads the
factory's account on the host's one nats-server, as the executor's user
of that account. What it reads on from after the bus goes away is still
the last id it held; an id now carries the stream's creation time, so one
from before a restart is not read as a neighbour of one from after, and
the relay takes the stream from its start instead of skipping what it
never saw.
