---
id: ADR-065
title: At the ceiling the executor holds the decider, and the proof reaches the ceiling itself
status: implemented
date: 2026-09-16
status_date: 2026-09-16
summary: no decider session is restarted while the proxy refuses; isolation.sh spends its way to the limit itself
depends_on: [ADR-035, ADR-037]
supersedes: []
superseded_by: []
---

## Context

ADR-037 point 4 gives a factory two limits: at nine tenths of the ceiling
the executor routes nothing new, and at the ceiling the proxy answers 429
itself. Running `tests/manual/isolation.sh` on 2026-09-16 with a ceiling of
300 tokens showed what the machine does past the second one. The decider's
first thought spends 6273 tokens (the rules, the policy, the declaration
and the board, whole, as ADR-034 point 5 has it), so the ceiling was
reached by the one role that does no work before anything else asked. From
then on every decider session got 429 three times from pi's own retry,
settled, shut itself down as a thought's end (ADR-035 point 4 as amended),
exited 0, and was started again by the executor two seconds later: a fresh
session every twenty seconds, for as long as the machine ran. Nothing was
spent, since the proxy refused every request, but the executor was
restarting a process the proxy would answer nothing to.

The cause is the restart itself: `RoleSessions` restarts every session on
exit and reads nothing to decide whether to. The count could not have
stopped it either way. A fresh decider process begins with an empty ready
set, so its snapshot differs from the one the last process remembered,
and the guard against thinking twice about one board does not hold across
a restart; every process thinks once, which under ADR-035 is what a
process is for. The snapshot carries `routing` for the model to read, but
the request that carries it is the one the proxy refuses.

The same run showed the proof's own assumption broken. `isolation.sh`
gates its hard-limit scenario on a ceiling under 5000 tokens, on the
reasoning that fifty one-token requests spend a few thousand. With a live
decider no such ceiling survives to the proof's first request, and with
the example's twenty million the scenario is gated and never runs. The
two Thens of that scenario, that the sender's count moves and that the
proxy answers 429 at the limit, are today proved in two runs with two
ceilings, never in one.

## Decision

**1. The executor restarts no decider session while the proxy refuses.**
On a decider session's exit the executor reads the proxy's count as
`mayRoute` does. Below the ceiling the session is restarted as today. At
or above it, where the proxy answers 429 to everything, the session is not
restarted, one `decider_held` event goes to `events:executor` saying the
ceiling is reached, and the main loop's outcomes check, every ten seconds
today, is where the count is asked again: a count below the ceiling, which
today means the proxy restarted with the machine, starts the decider once
more with a `decider_resumed` event. The count
can cross between the read and the spawn; that costs one thought the
proxy refuses, and the next exit holds.

The hold is at the hard limit and not the soft one. Between the two the
executor refuses `assign` and `retry` and accepts `file`, `block`, `push`
and `stop`, which are the verbs a factory at the end of its budget most
needs: work already done is pushed and a role still spending is stopped.
A decider held at nine tenths could ask for neither.

**2. The soft limit stays where it is.** The executor refuses to route at
it and the decider's snapshot carries `routing` so the model knows why an
assign would be refused. Nothing here moves that split: the executor
holds every mechanism of the budget, and the decider is told the state.

**3. Roles' sessions are not held.** An idle actor spends nothing, and a
running turn at the ceiling gets the proxy's 429 and ends as any failed
turn does; the executor's restart then waits for an assignment that is
never routed. Their restarts are not the loop observed.

**4. The proof reaches the ceiling with its own requests.** The hard-limit
scenario of `isolation.sh` sends a prompt of a known size, about two
hundred tokens, and fifty of them spend ten thousand; the proxy counts
`prompt_tokens` whole whether the provider cached them or not. Its gate
becomes a ceiling under twenty thousand, which leaves the decider's first
thought and a second on the ready set's change under it with room to
spare, so that the count-moved Then and the 429 Then hold in one run on
one ceiling. `docs/roadmap.md` 6.7 and ADR-064's record say the scenario
was gated at the example's ceiling; after this they say it ran.

**5. What is not decided.** No backoff on a session that exits fast. A
task finished in under a minute is a normal fast exit under ADR-035, and
a growing delay would slow the factory where it is working best. The one
crash loop observed has one cause, and point 1 removes it. Nothing is
done about the remembered-snapshot guard that a fresh process defeats:
one thought per process is ADR-035's design, and a thought that lands
below the ceiling is what the decider is for.

## Consequences

The executor gains a second reader of `/status` beside `mayRoute`: the
decider's restart path, and the main loop while a decider is held. The
read is one HTTP GET on the bridge, against a proxy that answers from
memory. The restart decision belongs to the core, which owns `mayRoute`
and the declaration; `RoleSessions` stays the mechanism it is, and
`tests/command/seam.bats` sees no change to the session line.

A held decider means a board that changes at the ceiling is not looked
at, which is the point: the proxy would refuse the look. The operator's
event says why the factory is quiet. When the count is reset by a machine
restart the decider comes back on the next read without an operator's
hand.

The proof spends more per run, about ten thousand tokens of a real
provider's at the cheapest model, where it spent a few hundred. Accepted:
it is the one scenario that proves the hard limit, and it runs when the
operator runs it.

## Verification

The executor's scenarios with the fake spend the core's tests already use:
the ceiling is reached at the count and not below it, not between the
soft limit and the ceiling, and never with none declared. The sessions'
scenarios with a program that exits at once: an exit whose restart is
allowed is started again; one whose restart is refused is held and not
started; a held session is started again by `start`; a stopped session's
exit asks nothing. The wiring in `main.ts`, that the question is asked
for the decider alone and the events are published, is glue the journey
runs and the machine proves.

On a machine, `tests/manual/isolation.sh` with a ceiling of fifteen
thousand: the count-moved Then and the 429 Then both `ok` in one run, and
after the 429, `sshm journalctl -u fabriek-executor | grep -c 'session
decider exited'` reads the same number two minutes apart while
`fabriek-executor` stays active. Recorded here when run.

Implemented 2026-09-16: `Executor.atCeiling` in `factory/src/executor/core.ts`
reads the count against the declared ceiling; `RoleSessions` in
`sessions.ts` asks `mayRestart` on every exit, holds a session refused
and reports it under `held()`; `main.ts` asks for the decider alone,
publishes `decider_held` and `decider_resumed` on `events:executor` and
starts a held decider again from the ten-second outcomes check.
`tests/manual/isolation.sh` sends a padded prompt, gates on twenty
thousand, and asks the executor's journal after the 429. Measured on a
machine built from this change at a ceiling of 15000 tokens: every Then
`ok`, none gated, in one run: the sender's count moved, the proxy
answered 429, the executor said the decider is held, no decider session
exited in the forty-five seconds after, and `fabriek-executor` stayed
active. The package's 185 scenarios and the journey pass.
