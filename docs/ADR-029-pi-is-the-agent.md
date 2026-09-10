---
id: ADR-029
title: pi is the agent a role runs, because it is the one we can change
status: proposed
date: 2026-09-08
status_date: 2026-09-08
summary: the choice is the licence and not the protocol, since the console and the ledger are built on records the agent defines
depends_on: [ADR-021, ADR-024, ADR-026, ADR-027]
supersedes: []
superseded_by: []
---

## Context

A role runs an agent, and which one has never been written down. ADR-020 lets
a declaration name any command, the example names `claude`, and three decisions
since have quietly assumed something else.

The assumption stopped being quiet at ADR-021. The loop owns the agent's stdio,
the console is three of the agent's own verbs (ADR-026 point 4), and the ledger
and the transcript are that agent's event stream split in two, named record by
record: `message_update`, `tool_execution_*`, `turn_start`, `agent_settled`
(ADR-027 point 3). Those are structure rather than preference. A factory that
changed agents would not re-implement its console and its ledger, it would
re-decide them.

Four were on the table. What each has to provide is not a general judgement of
agents; it is the list ADR-021, ADR-026 and ADR-027 already committed to.

| | Claude Code | Codex CLI | opencode | pi |
| --- | --- | --- | --- | --- |
| Licence | closed | Apache-2.0 | MIT | MIT |
| Transport the loop can own | stdio, `--print --output-format stream-json` | stdio, `codex exec --json` | HTTP server, `opencode serve` + SSE | stdio, `--mode rpc`, JSONL with LF the only delimiter |
| One client, so who may steer is settled | one pipe | one pipe | multi-client by design | single client, stated as such |
| Mid-turn direction | `--input-format stream-json` | none found | `POST /session/{id}/abort` | `steer`, `follow_up`, `abort`, `clear_queue` |
| Replay for a late joiner | `--resume <id>` | `exec resume --last` | session API | `get_messages`, session JSONL tree, `fork` |
| Events a ledger can be split from | stream-json records | `--json` progress | SSE events | `turn_*`, `message_*`, `tool_execution_*`, `agent_settled` |
| Shape of a run | long-lived session | one task to completion | client and server | long-lived session |

Three things fall out of that table, and only the last is about licences.

**opencode is ruled out by a decision already taken here.** ADR-026 point 2
refuses a TCP port for the console, because cages share the machine's network
namespace (ADR-025) and a loopback port lets any role drive any peer's agent.
opencode's headless mode is an HTTP server with multi-client sessions and its
own auth. That is a reasonable design and the wrong one to put inside a cage
that already has a network namespace it does not own.

**Codex is shaped for a different job.** `codex exec` runs one task to
completion and exits, which is what a CI step wants and not what ADR-021's loop
is. Nothing found exposes mid-turn direction, which is ADR-026 point 4 outright.

**Claude Code fails on none of it, and that is the point.** It takes
`--print` with `--output-format stream-json` and `--input-format stream-json`,
verified on the host this was written on: a programmatic protocol over a pipe,
of the shape ADR-026 reads. Between it and pi the capability comparison does
not decide anything, and an ADR pretending otherwise would be reopened by the
first person to read `--help`. What decides it is that pi is MIT and Claude
Code is not.

## Decision

**1. pi is the agent this repository supports, and the reason is the licence.**
Not the protocol, which more than one of the candidates has.

**2. The records the factory is built on are ones it can read, pin and fork.**
ADR-026 and ADR-027 consume specific event kinds and specific verbs. A closed
agent may rename or drop any of them between releases, and the console and the
ledger break with no recourse beyond waiting. An open one is pinned like every
other input here, read when its behaviour is in question, and changed where it
does not do what a factory needs.

**3. It is a choice, not a restriction.** The declaration still names a command
and nothing validates it. This document records which agent is supported; a
role naming something else is undefined rather than refused. Narrowing the
schema would be a separate decision with a separate cost, and nothing yet needs
it.

**4. The example declares pi, and provides it.** It declared `claude` and
provided nothing, so the repository contradicted this before the ink was dry
and the command named a binary no shell had. `pi-coding-agent` is in nixpkgs,
and it goes in the project's own devShell for the reason ADR-016 gives for a
specialist's toolchain: what a role has to hand is the project's business, not
cageworks'.

**5. ADR-026 point 9 stops being a hedge.** "A role whose agent speaks no such
protocol has no console" was written as a property to accept. It is now the
statement of what is outside the supported case, which is the same sentence
doing a different job.

**6. The agent reaches the egress proxy through a file, not a variable.**
ADR-026 parked this as "which variable points the agent at the egress proxy",
and there is no such variable. pi overrides a built-in provider's `baseUrl` in
a `models.json` under its configuration directory, which `PI_CODING_AGENT_DIR`
names, and the override is per provider, which is the shape ADR-025's per-host
locations already have. So it is composed and bound like the signing key and
the guidance, and ADR-026's sentence is corrected there rather than here.

**7. A caged agent is told not to reach the network on its own.** `PI_OFFLINE`
disables pi's startup network operations. ADR-025 drops egress on the machine
and lets out one uid, so those calls do not fail interestingly, they fail as a
slow start nobody has attributed.

## Consequences

**The coupling is now explicit rather than accumulated.** It was already total
by ADR-027 and undeclared, which is the worse of the two states: a reader of
ADR-020 would have believed the agent was a free choice.

**Replacing pi means re-deciding ADR-026 and ADR-027, not re-implementing
them.** The console's verbs and the ledger's fields are pi's vocabulary. That
is the bill for building on one agent's protocol, and it is paid whichever
agent is picked.

**Being able to change the agent cuts both ways.** A fork is a thing this
factory then maintains, and the reason to pick an open agent is worth nothing
if nobody ever reads it. The claim here is that the option exists, not that it
is free.

**And the upstream may become that fork whether or not it is chosen.** pi is a
small project; the alternative it was picked over has a vendor and a team. The
licence argument says a stall upstream is survivable, and it is: everything
this factory reads is a record format that can be kept working. It does not say
a stall is unlikely, and on project size the comparison runs the other way. The
honest form of the decision is that a dependency which can be repaired late is
worth more here than one that cannot be repaired at all, not that the first
will need repairing less often.

**The alternative that was not disqualified is Claude Code.** Anybody reopening
this should do it there and on the licence argument, which is where the
decision actually rests. Reopening it on capability means showing the table is
wrong, which is a different and more useful conversation.

**Points 6 and 7 are obligations, not observations.** Nothing composes a
`models.json` yet and nothing sets `PI_OFFLINE`. Until something does, a
factory declaring pi reaches the network the way pi does by default, which on a
machine that has dropped egress means it reaches nothing and says so late. This
document names the mechanism; wiring it is ADR-025's business and is not done
here.

**What the table records was read rather than remembered.** pi's flag, verbs
and events come from its own RPC documentation and from `--help` on the build
nixpkgs carries, and they are the same names ADR-026 point 3 and ADR-027 point
3 already consume, which is worth knowing because those two documents were
written from a spike rather than from a page. `--mode` takes `text`, `json` or
`rpc`, so the declaration's `--mode rpc` is the documented spelling.
Claude Code's flags come from `--help` on this host. Codex's and opencode's
come from their documentation and were not run. "None found" in the mid-turn
row means exactly that, and is the row most likely to be out of date first.

## Verification

```bash
docmeta-check docs && docmeta-tracker --check docs
nix eval --impure --expr '(builtins.getFlake (toString ./examples/factory-project)).cageworks'
nix develop --command bats --recursive tests/
```

The example is what makes this decision visible to anybody starting a factory,
so it is the thing that has to evaluate. Nothing in the suite asserts which
agent a role runs, and nothing should: point 3 says this is a choice rather
than a rule, and a test would make it a rule.
