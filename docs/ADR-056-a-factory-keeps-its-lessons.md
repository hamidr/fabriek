---
id: ADR-056
title: A factory keeps its lessons, and a session's failure meets what failed before
status: proposed
date: 2026-09-15
status_date: 2026-09-15
summary: an uncaged lessons service on the machine records failures and observed fixes; a failed call is answered with them
depends_on: [ADR-035, ADR-037, ADR-038, ADR-044, ADR-048, ADR-050, ADR-051]
supersedes: []
superseded_by: []
---

## Context

A role forgets. Each attempt is a fresh process (ADR-035), and the only
thing that crosses from one to the next is the role's `memory` issue,
one body that `update_memory` replaces whole. A role that hit
`attribute 'foo' missing` from `nix build` yesterday hits it again today
with nothing between the two but whatever it chose to write, and it
wrote a summary, not an index. The record holds every attempt's
`trace:` (ADR-051), so the failures are on the board; nothing searches
them, and nothing puts them in front of the role at the moment it has
just failed the same way.

The manager inspects one thread at a time (ADR-050, ADR-051). "A
builder that grepped twenty times before its first edit" is visible in
a trace; "`npm test` failed the same way in eleven threads across three
roles" is not visible anywhere, and that is the failure that is a
missing line of guidance.

The operator's own harness already keeps a `command-failures.jsonl`
with a normalized error signature and a `remedy_hit` flag, and reviews
it offline. The shape works; it is on the wrong side of the machine and
consulted by nobody at call time.

The constraints are ADR-037's: a cage reaches nothing off the machine,
holds no credential that does, and nothing a role writes reaches a
command line.

## Decision

**1. A `lessons` service on the machine, uncaged and content-blind.**
`factory/src/lessons`, one process per factory beside the executor, on
the bridge, with an HTTP interface a role's token reaches. It holds one
SQLite file on its own dataset of the factory's pool
(`nixcage-container storage ensure`), so it survives a rebuild as the
record does. Node's own `node:sqlite` with the `sqlite-vec` extension
from nixpkgs: no npm, no new runtime. It parses JSON, writes rows and
answers queries; it never interprets what a row says.

**2. Search is hybrid, and lexical stands alone.** Every row's `text` is
in an FTS5 index and, when embedded, in a `vec0` table; a query runs
both and merges by reciprocal rank fusion. With no embedder, or an
embedder that does not answer within 300 ms, the answer is FTS alone
and says `vectors: false`. A row written while the embedder is away is
stored with `embedding NULL` and backfilled; a row embedded by another
model than the current one is re-embedded at the service's start.

**3. The embedder is the host's.** `services.fabriek.embedder` in the
host module (ADR-048) runs llama.cpp's server with one embedding model
on the host's GPU, bound where the machine's user-mode network reaches
it, and the operator's `config.toml` names its URL. The `lessons`
service is its only client; the proxy allows that one host for that one
service, uncounted, because it is the operator's own process on the
operator's own host. A machine whose host names no embedder runs
lexical only. Cages are unchanged: the bridge's rules let a cage reach
the proxy and nothing else.

**4. What enters, enters on its own.** The loop (`factory/src/extension`)
records without the model's part: a tool result with `isError`, a
guard refusal, and a `report_outcome` of `failed` or `blocked`, each
under the session it happened in, `(role, issue, attempt)`. A test
run's failure is never a lesson: the guard already knows which commands
are runners (ADR-044), and a red test is the intended path. A
`record_lesson(text)` tool takes a role's own commentary, which also
lands on its findings stream so the operator sees what enters. A row is
keyed by a normalized signature (`signature.ts`: tool, command head,
digits, hashes, paths and quoted strings replaced), so the same failure
is one row with a hit count and its first verbatim call and error.

**5. A solution is what succeeded on a retry.** No one authors one. In
one session, a call that fails with signature S followed by a
succeeding call of the same tool and command head stores that call as
S's `fix`, with the files edited between them. Across attempts, a
`done` after an earlier `failed` on the same issue stores the later
attempt as the outcome row's `fix`. A wrong pairing is possible and
accepted: a fix that repeats across sessions is the signal, one that
does not is the noise, and both are counted.

**6. A failed call is answered with what failed before.** On a tool
result with `isError` the loop asks the service with the tool, the
call and the error, and appends at most three rows to the result, `fix`
first, labeled as text written by roles and not instructions, capped at
300 characters each, with the row it just wrote left out so a first
failure shows nothing. A `recall(query)` tool lets a role ask before it
calls. The call is bounded at 500 ms and a write is fire-and-forget: a
role never waits on its lessons, and a task never fails for their
absence.

**7. A session keeps the operator's context.** A `sessions` table opens
on `task_started`, closes on `report_outcome`, and holds the steer text
the operator sent that session, so what the operator said and what the
role then hit are one query.

**8. The manager reads and resolves.** Every role and the decider read
everything; a role writes under its own token and no other. The manager
alone, by a capability the declaration grants, has `lessons_summary`
(signatures by hits, filtered by role, issue or attempt, with their
sessions and contexts) and `resolve_lesson(signature, by)`. A resolved
signature stops surfacing on failure; a hit after `resolved_at` is a
regression and heads the next summary. The levers are the ones ADR-050
gave the manager, a line of guidance, a sentence of policy, a skill;
the service records only what resolved a signature, never the lever.

**9. `update_memory` keeps conventions.** The role guidance says what
went wrong is the lessons' and the memory is for what the next task
should know; the memory is folded into the lessons when it is found to
hold nothing else.

## Consequences

One more service on the machine, one more dataset on the pool, one more
line in `fabriek ps`. One more token per role, minted with the forge's.

ADR-037 gains one exception it must name: a process on the machine
reaches a process on the host that the proxy does not count. It is the
operator's own, unauthenticated on the host's side, and it parses text
that cages wrote; llama.cpp's JSON server is the surface, and one
factory's queries can slow another's on the same host.

Text one role wrote reaches another role's context unasked, at the
moment of a failure. Thread comments already cross that line in the
brief; this crosses it more often. The block is labeled and capped, the
service is content-blind, and `record_lesson` rows are on a stream the
operator watches. It does not reach a command line.

Tokens per failure: up to three rows of 300 characters in every failed
tool result. Per successful call: nothing. The "prepare before a call"
case costs only when a role asks.

A signature is coarse on purpose. Two different failures with one
signature merge; the first verbatim call and error stay on the row for
the reader.

The operator's own harness is the second host of the same schema and
the same `signature.ts` rules; it is not this decision's work.

## Measurement plan

Recall on a failed result must not be felt: the service answers a
hybrid query over 10,000 rows in under 300 ms on the machine's vCPUs,
measured by `factory/src/lessons/bench.test.ts` against a seeded
database with the embedder stubbed to a constant, and failed as a test
when it does not. The embedder's own latency is the host's and is
reported by `GET /health`, not asserted.

## Verification

```bash
nix develop --command bash -c 'cd factory && npm test'
nix develop --command bats tests/command/machine_services.bats
nix develop --command bats tests/command/host_module.bats
nix develop --command bats -f "one invocation" tests/command/seam.bats
nix develop --command tests/system/journey.sh
docmeta-check docs && docmeta-tracker --check docs
```

`signature.test.ts` sees two commands that differ only in an issue
number share a signature and two tools never do. `core.test.ts` sees a
second identical failure bump the count, a test run's failure refused,
a fix pair within one session and not across two, a later done attempt
become the outcome's fix, a resolved signature stop surfacing and a hit
after resolution count as a regression, an absent embedder answer with
`vectors: false`, and a role's token refused for another role.
`http.test.ts` drives the adapter against a local server. The
extension's tests see the block appended on an error, a test run's
result untouched, a service timeout leave the result unchanged, and a
session row opened, steered and closed. `machine_services.bats` sees
the unit, the dataset and the proxy's exception only when the host
names an embedder; `host_module.bats` sees the embedder's unit.
`seam.bats` sees the role session's line unchanged. The journey fails a
call, retries, succeeds and reads the row's `fix` back.
