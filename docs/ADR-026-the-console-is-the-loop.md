---
id: ADR-026
title: The operator's console is the loop, not a terminal
status: superseded
date: 2026-09-07
status_date: 2026-09-12
summary: the loop owns the agent stdio and relays a role-owned socket the operator watches and steers, so nothing detaches
depends_on: [ADR-021, ADR-024, ADR-025]
supersedes: []
superseded_by: [ADR-039]
---

## Context

ADR-021 decided that herdr attaches to a running agent rather than starting one,
and listed the bill for it: "A console that survives detaching has to be built."
That sentence rests on an assumption nobody checked, that the agent owns a
terminal and an operator joins it.

Reading what a role actually runs removes the assumption. pi's RPC mode is
"strict JSONL semantics with LF (`\n`) as the only record delimiter" over stdin
and stdout. There is no listener, no socket and no port. The client is whoever
holds the pipe, and there is exactly one of those.

Two things follow. An operator's own pi cannot connect to a role's pi, because
nothing there accepts a connection. And herdr attaching to a running agent can
only mean herdr attaching to a terminal, which puts the agent's stdio behind a
PTY that outlives a pane: tmux inside the cage, or `dtach -N` with `-a` and
`-r winch` (verified against dtach 0.9). Both work. Both exist to carry a
constraint that turns out not to be there.

The single client is not an obstacle to route around. It settles who may steer,
which is the half that was hard. Watching was never bound by it, since pi
persists a session and a second process could render one from `--session-dir`
without touching the pipe. The loop already spawns the agent, already reads and
writes the record, and already checks the budget (ADR-021 points 2 and 5). Give
it the pipe, and the console stops being a terminal problem.

## Decision

**1. The agent is a subprocess of its loop, and the loop owns its stdio.** No
PTY, no multiplexer, no detach, no redraw, no scrollback.

**2. The loop exposes one unix socket per role,** on a runtime path of its own
under the state directory and owned by the role's uid. Not in the role's
worktree, which is a git working tree the role commits from, and not a TCP
port: cages share the machine's network namespace, which is the fact ADR-025
depends on, so a loopback port would let any role drive any peer's agent. The
path reaches the loop as a bind on the session, so what a role can open is
decided by what its cage was given rather than by a mode on a shared directory.

**3. Watching is a subscription.** The loop relays the agent's events
(`turn_start`, `message_start`, `message_update`, `message_end`,
`tool_execution_*`, `agent_settled`). A late joiner gets the transcript first,
asked for with `get_messages`, so an attach is never a blank screen. Any number
of readers, nothing to arbitrate.

**4. Speaking is three verbs, and they are the agent's own.** `steer` queues a
message after the current tool calls, `follow_up` queues one after it settles,
`abort` stops the turn. This is the mid-turn direction ADR-021 point 6 wanted,
as messages rather than keystrokes.

**5. Every operator message passes the loop, so it is recorded.** A comment on
the task the role holds, for `steer`, `follow_up` and `abort` alike.

**6. Directing costs a turn and stopping does not.** `steer` and `follow_up`
each count against `budget.runs`, which answers PRD-005's open question, and
`abort` is free. Charging for a stop would price ending a runaway turn at the
same as letting it finish, and an operator would pay most where the factory is
going worst.

**7. The operator's client is theirs, not ours.** fabriek publishes the
socket over the key and port a factory's machine already has. What drives it is
outside this repository, as which agent a role runs already is.

**8. herdr leaves the design, and leaves the code with it.** `herdr_socket`,
`herdr_report_state`, the `--pane` flag on a role session and the pane test go
in the same change, because a retained path to a second console would be a
second answer to the question this document settles.

**9. A role whose agent speaks no such protocol has no console.** Stated as a
property rather than repaired with a PTY fallback, because a fallback would
reintroduce everything points 1 through 4 remove.

**10. The agent is a child of its loop in one unit.** Stopping the unit stops
both, so a loop cannot die and leave an agent spending the budget nobody is
counting any more.

## Consequences

ADR-021 point 6 no longer describes what is built, and its console consequence
is withdrawn rather than paid: nothing survives detaching because nothing is
attached. Points 1 through 5, 7 and 8 stand untouched, so that document is
amended here and not superseded, and its point 6 goes on reading as current to
anyone who opens it alone. The frontmatter has no field for a partial
withdrawal and inventing one would put two meanings on `superseded`, so the
drift is accepted and recorded here. PRD-005 phase 4 becomes a relay and a
client.

**The socket is a way into the cage.** pi's RPC surface includes `bash`, so
whoever reaches the socket runs commands in the cage under the role's uid.

**And the agent is already inside it.** `--private-users=<uid>:1` maps a
session onto one uid, so the loop and the agent it supervises are the same
principal. An agent with `bash` can therefore open its own console socket and
steer itself, write the comment that point 5 says records an operator, or kill
the loop that counts its turns. This is ADR-021 point 5's weakness widened from
the budget to the record: attribution of an intervention is correct for an
agent behaving normally and is not proof against one that is not. Separating
the two would need the loop and the agent under different uids in one cage,
which the enter primitive cannot express, so it is an interface change in
nixcage before it is a change here. Until then the property is stated rather
than claimed.

That interface change has since landed, and ADR-028 spends it: a cage now maps
a block, the loop enters as cage root and the agent runs as a subject, so an
agent cannot signal the loop or open what the loop owns. This paragraph is
what ADR-028 exists to repair and is left standing as the reason it does.

The loop becomes load-bearing for watching. A dead loop is a blind operator,
where a PTY would at least have kept showing the last screen.

Consoles stop being agent-agnostic. A factory whose roles run something without
an equivalent protocol gets no console at all.

herdr goes from being PRD-003's control plane to being absent. That document is
implemented and says the console and the control plane are the same thing, so
it stops describing what runs here, and the code and test that make it true go
with the decision rather than after it.

Which variable points the agent at the egress proxy stays where ADR-025 put it,
in the declaration's own command, and is not decided here.

There turns out to be no such variable. ADR-029 picked the agent and found that
pi is routed through a proxy by a `models.json` in its configuration directory,
overriding a built-in provider's `baseUrl`. That is a file to compose and bind,
the way the signing key and the guidance already are, and not a word in a
command. The sentence above is left standing as the assumption it was.

## Design gates

The Formal Modeling Gate fires on point 3. Queueing a steered message against a
running turn is the agent's own concurrency and not this repository's, but a
watcher joining a stream that is already running is ours: it takes a
`get_messages` snapshot and then subscribes, and anything the agent emits
between the two is lost or delivered twice. The stream is stateful, since a
message must be assembled from `message_start` and the updates that follow it
and only `message_end` is authoritative, so a gap does not announce itself as
one. `models/console-watch.qnt` is written and run before phase 4, over the
interleavings of snapshot, subscribe and emit, with one invariant: a watcher's
assembled transcript equals the agent's at every settle.

A permission changes too. A role owns one more path, so
`models/factory-structure.als` gains the console socket beside the worktree and
the refs it already carries, in the same commit as the implementation.

## Verification

```bash
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/
nix develop --command bats tests/command/seam.bats
alloy6 exec models/factory-structure.als
quint run models/console-watch.qnt --invariant=allInvariants --max-steps=60
docmeta-check docs && docmeta-tracker --check docs
```

The suite asserts what the socket is rather than what it carries: a console
socket is owned by its role and no other role can open it, a second watcher
receives the transcript before the next event, an operator message reaches the
record as a comment on the held task, a spent budget refuses a steer as it
refuses a turn, and an abort is recorded without being charged. `seam.bats` is
named on its own because a loop that starts a role session changes the argv it
asserts whole, and that diff is the point of the file.
