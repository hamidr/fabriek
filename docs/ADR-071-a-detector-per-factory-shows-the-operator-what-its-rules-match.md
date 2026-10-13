---
id: ADR-071
title: A detector per factory reads its logs and probes with rsigma and shows the operator what its rules match
status: proposed
date: 2026-10-13
status_date: 2026-10-13
summary: rsigma per factory on the host over its logs and probes; detections to the TUI and the trace, never acted on
depends_on: [ADR-037, ADR-038, ADR-051, ADR-067, ADR-069, ADR-070]
supersedes: []
superseded_by: []
---

## Context

ADR-038 observes a factory from three sources: the thread, the proxy and
the kernel probes. Nothing reads the probes for what they mean: the trace
(ADR-051) counts executables, and the TUI prints the raw lines. A cage that
tries to leave, to pass for another cage, or to reach the kernel's
namespaces is refused by ADR-037's boundaries and the refusal is silent, or
written somewhere the operator does not look: the host's journal for the
proxy, the bus and the forge, nothing at all for the host's forward chain
and, before nixcage 5.3.0, for the bridge.

The operator wants those attempts collected and shown. rsigma
(github.com/timescale/rsigma, v0.24.0) evaluates Sigma rules over a stream
of JSON events, one static binary, with a linter and a backtest that CI
can drive. nixcage 5.3.0 (`749f664`) carries what it needs from below:
a bridge's drops logged with the prefix `nixcage-drop` at level err, so
they reach the machine's console and its unit's journal on the host; the
port and project in `list --json`; and the statement that a cage has no
journal socket (nixcage ADR-011).

## Decision

**1. One detector per factory, on the host.** A unit
`fabriek-<name>-detector` in the factory's slice, beside the executor
(`modules/host/executor.nix`). A detector that fails blinds one factory,
and the unit's state is what `fabriek ps` shows. It is uncaged and reads
what a role wrote only as data: nothing it reads reaches a command line
(invariant 1).

**2. A feeder merges the factory's sources into one line per event.**
`fabriek-container detector-feed` follows the host's journal and the
factory's `probes` stream and writes one JSON object per event on stdout:
`ts`, `factory`, `role` when known, `source`, `role_claimed`, and the
source's own fields. The sources:

- `probes`: the kernel's exec, exit and connect, with `type`, `uid`,
  `pid`, `comm`, `image` and, for a connect, `dst_ip`, `dst_port` and
  `dst_allowed`, which the feeder sets against the factory's
  `bridge.json` so the rules need no factory's addresses.
- `proxy`: the factory's nginx server, whose `fabriek_egress` log format
  becomes `escape=json`. Nothing reads that log today.
- `firewall`: the host's forward chain drops from and to `fb-*` with a
  rate-limited `log prefix "fabriek-drop "` (`modules/host/proxy.nix`).
- `bridge`: nixcage's `nixcage-drop <reason>` lines from the machine
  unit's journal, the role named from the port through `list --json`.
- `bus`, `forge`: the host's nats-server and Forgejo lines that name one
  of this factory's users (`<factory>-<role>`). A shared service's line
  that names no user of this factory never enters this detector.
- `executor`: the factory's slice units.
- `session`: what a role's session writes on stdout and stderr, which the
  executor tags with the role it started (`executor/sessions.ts`). A cage
  has no journal of its own, so this is the only place a role's own words
  reach the detector, and every such line is `role_claimed: true`.

**3. rsigma is a filter, and fabriek owns the bus.** The unit runs the
feeder into `rsigma engine daemon --input stdin --output stdout` and its
output into `nats pub detections`, as the factory's `detector` user, who
may subscribe to `probes` and publish to `detections` and nothing else.
rsigma's own NATS input is not used: v0.24.0 creates a stream of its own
over the subject it reads and refuses to start beside ours, and needs
rights to create streams that no reader here has (ADR-069 point 5). No
`--state-db`: correlation windows start empty after a restart, and nothing
persists the event stream (ADR-038 point 2). No webhook, file or OTLP
sink: nothing leaves the host.

**4. The rules are fabriek's and the operator's.** fabriek ships a ruleset
under `modules/host/detection/`; `services.fabriek.detection.rules` names
the operator's directory beside it. The repository a factory works
declares none: its roles can commit to it, and a rule the watched party
can edit watches nothing. The unit runs `rsigma rule validate` over both
before it starts, so a broken rule fails the unit rather than starting
detection on half a ruleset.

**5. Levels say what was crossed.** `high` is a cage trying to cross a
boundary: an escape tool, a connect outside the plan, a bridge or firewall
drop, a bus authorization failure, a miner. `medium` is a tool a cage has
no reason to run (`nc`, `socat`, `nmap`, `ssh`), a bus permission
violation, a forge login that failed. `low` is noisy, or claimed: a 403 or
404 at the proxy, and every rule over `session`, which a role can forge
or flood and which therefore never rises above `low`.

**6. The operator sees every detection; nothing acts on one.** Each goes
to the factory's `detections` stream, capped at 10000 entries as `probes`
is, as `{rule, rule_id, level, role, source, role_claimed, ts, event}`.
The relay forwards it; the TUI keeps the last fifty, marks the claimed
ones, counts each role's high detections beside its name, and strips
control characters from every field before it renders one, since `event`
can carry a role's text. The trace (ADR-051) adds one line for the
attempt's window and role: each level with its count and rule titles,
never `event`, because the record is mirrored off the host. The executor
may subscribe to `detections` to cut that line and does nothing else with
it. Stopping or steering a role on a detection is a later decision, once
there are false positives to weigh.

**7. argv is not probed.** The probes carry the executable's path, not its
arguments. argv is read at `sys_enter_execve` before the exec succeeds,
bounded per argument, and carries what a role passes on a command line,
its forge token among it; the probes stream is read by the relay, the TUI
and the trace. A rule over command lines waits for a source that keeps
argv from every reader but the detector.

## Consequences

The probes stream changes shape: its entries carry fields instead of one
`event` line, and `executor/trace.ts`, `tui/model.ts` and
`relay/format.ts` move with it in the same change. Each factory's bus
gains a user and a stream; each host gains a unit per factory and a
binary that is not in nixpkgs, packaged from its release archive with its
provenance checked, as `modules/codegraph/` is.

A detection is a claim about a line, not a verdict: an executable's path
inside a cage is a store path (`/nix/store/<hash>-util-linux/bin/nsenter`),
so rules match its end, and a role can rename its process, so `comm` is a
hint. What the boundaries refuse stays refused whether or not a rule
matches it.

Moving the probes onto nixcage's `machine trace` (nixcage ADR-028) is not
part of this: that ADR is proposed, and the program fabriek runs in the
machine already works.

## Verification

- `tests/unit/detection_rules.bats`, with real rsigma: the ruleset lints
  clean; each rule fires on its fixture under
  `tests/fixtures/detection/`; a benign corpus of what roles do passes
  `rule backtest --unexpected fail`; every rule over `session` is `low`.
- `tests/command/probes.bats`: an exec carries its path and a connect its
  destination.
- The feeder's bats, with `journalctl` and `nats` stubbed: each source
  becomes its line, a shared service's line naming another factory's user
  is dropped, a session line is claimed.
- `prepare.bats`: the detector may subscribe to `probes` and publish to
  `detections` only; the executor may subscribe to `detections`.
- `host_module.bats`: a detector unit per declared factory, in its slice.
- `model.test.ts`, `trace.test.ts`, `format.test.ts`: a detection is shown
  with its level and role, a claimed one marked, a high one counted, no
  control character reaches the view; the trace counts the window's
  detections for its role and never prints `event`; `streamsFor` names
  `detections`.
- `tests/manual/detection.sh`, on a host: a cage spoofing an address and
  a cage running `nsenter` each reach the operator's TUI as a high
  detection within a second, and the attempt's trace names both.
