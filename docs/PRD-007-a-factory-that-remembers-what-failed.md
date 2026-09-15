---
id: PRD-007
title: A factory that remembers what failed, and a manager who reads it across threads
status: proposed
date: 2026-09-15
status_date: 2026-09-15
summary: a role that fails a call is shown what failed that way before and what then worked; the manager sees it summed
depends_on: [PRD-006]
supersedes: []
superseded_by: []
phases_total: 5
phases_done: 0
---

## Problem

A role starts every attempt with no memory of the last one but a summary
it wrote itself. When a call fails, it has only the error in front of it,
and it works out the fix again: the same missing attribute, the same flag
`nix build` wanted, the same runner that needs `--runInBand`. The record
holds every attempt's trace, so the factory has seen the failure before;
the role has not, and nothing tells it.

The manager, whose one job is the flow, reads one thread at a time. A
failure that recurs across threads and roles is exactly the failure that
a line of guidance or a skill would end, and it is the one nothing shows.
The operator's steer, typed into one session, is gone when that session
ends, so "I told it X and it still hit Y" cannot be read back either.

The operator's own harness keeps a log of failed commands and reviews it
offline. It has proven the shape: a normalized signature, a hit count,
whether a remedy covered it. The factory has no equivalent on its side of
the machine.

## Users

- **A role**, at the moment a call fails: wants what failed that way
  before and what then worked, without asking for it, and without being
  slowed or blocked by the asking.
- **A role**, before a call it is unsure of: wants to ask.
- **The manager**, at inspect: wants failures summed across tasks, roles
  and sessions, with the operator's context beside each, and a way to
  mark a signature answered so a return of it stands out.
- **The operator**: wants to see what enters a shared memory that roles
  read from, and wants the machine to reach nothing new off itself but
  what the operator's own host provides.

## Goals

1. A failed tool call is answered, in its own result, with what failed
   that way before and, when observed, what then succeeded.
2. What succeeded is observed, never written: the retry that passed, the
   attempt that ended done after one that failed.
3. Lessons survive a machine rebuild, as the record does.
4. The manager reads failures per task, per role and per session, with
   the operator's steer for that session, and closes a signature; a hit
   after closing is a regression at the top of the next summary.
5. A cage holds no new credential and no new route; a role never waits on
   the service and a task never fails for its absence.
6. Search finds the same error under different words when the host lends
   a GPU, and the same error under the same words when it does not.

## Non-goals

- Solutions authored by a model. `record_lesson` is commentary; a fix is
  what succeeded.
- The operator's own harness. It is the second host of the same schema and
  the same signature rules; it is its own PRD.
- Deleting or expiring lessons. The manager resolves; nothing evicts.
- A lesson store shared between factories, or one that travels with the
  repository. Per factory, on its pool.
- Recall before every call. Only on failure, and when a role asks.
- GPU passthrough into the machine.
- Token counting for the embedder. It is the operator's own process on
  the operator's own host.

## Success criteria

1. The system journey (`tests/system/journey.sh`) fails a call, retries,
   succeeds, and a later session of another role fails the same way and
   reads the fix in its tool result.
2. On a real machine with the host's embedder declared, `GET /health`
   reports `vectors: true`, and a query phrased differently from the
   stored error returns it; with none declared, the same query by the
   stored words returns it and health says `vectors: false`.
3. The manager's summary on a factory that has run three tasks lists
   signatures by hits with role, issue and attempt filters; a resolved
   signature is absent from a role's failed result and present, marked
   regressed, in the summary after one more hit.
4. `tests/command/seam.bats` is unchanged: a role session's line gains no
   flag.
5. A hybrid query over 10,000 rows answers in under 300 ms on the
   machine, as a test.
6. `tests/manual/isolation.sh` still passes: a cage reaches the proxy and
   nothing else, the embedder included.

## Requirements

### Recording

- R1. A tool result with an error, a guard refusal, and an outcome of
  `failed` or `blocked` are recorded under the session `(role, issue,
  attempt)` they happened in, with no action by the model.
- R2. A test runner's failure is not recorded and triggers no recall.
- R3. Failures are keyed by a normalized signature; a repeat is one row
  with a count, first and last seen, and the first verbatim call and
  error.
- R4. A role may add commentary with `record_lesson(text)`; it is on the
  role's findings stream as well.
- R5. A session row holds the operator's steer text for that session.

### Solutions

- R6. Within a session, a succeeding call of the same tool and command
  head after a failure is that failure's fix, with the files edited
  between.
- R7. Across attempts, a `done` after an earlier `failed` on the same
  issue is that outcome's fix.

### Recall

- R8. A failed tool result carries at most three rows, fix first, labeled
  as roles' text and not instructions, capped in length, the row just
  written excluded.
- R9. A role may ask with `recall(query)`.
- R10. Recall is bounded in time; a write is fire-and-forget; the
  service being down changes no tool result and fails no task.

### Search

- R11. Lexical search answers with no embedder; vector search joins it
  when the host's embedder answers; a row written while the embedder is
  away is embedded later; a change of model re-embeds.

### Manager

- R12. Every role and the decider read all; a role writes as itself only.
- R13. The manager, by a declared capability, reads a summary by role,
  issue and attempt, with sessions and their contexts, and resolves a
  signature with what resolved it.
- R14. A hit after resolution counts separately and heads the summary.

### Machine and host

- R15. The service is uncaged, content-blind, on the bridge, with its own
  dataset on the pool and a token per role.
- R16. The host declares its embedder in `services.fabriek.embedder`
  and `config.toml`; the machine's proxy allows that host for the
  service only; a cage cannot reach it.

## Constraints

- No npm and no new runtime: `node:sqlite` and nixpkgs' `sqlite-vec`.
- The invariants of `CLAUDE.md`: the service reads nothing a role wrote
  as anything but a row; a cage is nixcage flags and nothing else.
- Built behaviour first, in each component's own runner.
- ASCII in every document and every row's labels.

## Risks

- **Poisoning by the intended path.** Red tests recorded as failures
  would fill the store with the loop's own method. R2 is the guard; the
  test for it is the first written.
- **Cross-role injection.** A row one role wrote reaches another's
  context unasked. Labeled, capped, on a watched stream, never a command
  line. Accepted with those four.
- **Wrong fix pairing.** An unrelated success after a failure becomes its
  fix. Repetition across sessions separates signal from noise; the manager
  reads both.
- **Host surface.** llama.cpp's server parses cage-written text on the
  host; one factory can slow another's queries. Stated in ADR-056; the
  operator chooses to declare an embedder or not.
- **Noise volume.** Every non-test error becomes a row. Signatures
  collapse repeats; the count is the point. If the store fills with
  one-hit rows, the signature rules tighten, not the recording.

## Open questions

- Which embedding model ships as the host module's default, and at what
  dimension; the schema stores the model per row so it can change.
- Whether the memory issue is folded into lessons once it holds only
  conventions; ADR-056 defers it.
- Whether the decider's policy should route a role with an open
  regression to inspect first; the manager writes that sentence if so.

## Phases

1. **The core.** `signature.ts` and the service core against an
   in-memory database and a fake embedder: recording, dedupe, the test-run
   refusal, both fix pairings, resolve and regression, lexical-only
   answers, the per-role write check, the 10,000-row bound. Exit: every
   scenario green in `npm test`.
2. **The service on the machine.** The HTTP adapter, the unit, the
   dataset, the tokens beside the forge's, `fabriek ps`. Exit:
   `machine_services.bats` sees it; `seam.bats` unchanged.
3. **The loop.** Session rows, automatic recording, recall on error,
   `record_lesson` and `recall`, the guidance paragraph. Exit: the
   extension's scenarios green; the journey reads a fix back.
4. **The host's embedder.** `services.fabriek.embedder`, the config key,
   the proxy's one exception, backfill and re-embed. Exit:
   `host_module.bats` renders it; on a machine, health says
   `vectors: true` and a paraphrased query finds the row.
5. **The manager.** The capability, `lessons_summary`,
   `resolve_lesson`, the inspection prompt's sentence. Exit: success
   criterion 3 on a machine, scripted under `tests/manual/lessons.sh`.

## Design gates

Each phase's exit is a scenario run, recorded beside the phase here.
Phases 4 and 5 need a real machine and a host with a GPU, and are not
claimed from a stub.
