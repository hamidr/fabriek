---
id: PRD-005
title: Agents that take their own work from the record
status: proposed
date: 2026-09-06
status_date: 2026-09-06
summary: agents poll the record, take work by leased claim and run until stopped; the dispatching supervisor is not built
depends_on: [PRD-004]
supersedes: [PRD-002]
superseded_by: []
phases_total: 5
phases_done: 0
---

## Problem

The operator is the scheduler. PRD-002 said this three years of decisions ago
and it is still true: work that is ready waits until a person remembers it, a
finished turn sits idle until they notice, and roles that could progress in
parallel progress at the speed of one person's attention. PRD-003 built the team
and left the property in place deliberately, because no cage holding the program
that starts a run is a strong guarantee cheaply had.

What has changed is that the answer PRD-002 proposed cannot be built well. Its
supervisor decides what runs next from outside every cage, and deciding that is
reading the work: which of three open tasks deserves a turn, whether a stage's
bar has been met, whether a blocked task can move. The same document names
reading agent-authored text as its top risk, so its scheduler is required to
choose well and forbidden to look at what it is choosing between. Every
improvement to it walks into the risk it exists to avoid. ADR-015 already
conceded the shape once, making `done` prose that a role reads and the
supervisor never checks.

So the operator is the scheduler because the only alternative built so far is a
scheduler that must not read. The way out is to stop scheduling from outside and
let the worker choose its own next piece of work, which is the one place where
reading is what a cage is for.

That costs the guarantee. This document is the trade.

## Users

- **The operator.** Sets what may be worked and by whom, files goals, answers
  gates, and intervenes. They stop being the thing that starts every turn. They
  remain the only trust domain and the only thing that can stop an agent.
- **The role's agent.** Gains the ability to start its own turns. It gains no
  other authority: it still cannot write another role's refs, advance the shared
  branch, reach a remote, or change what the factory is.
- **The reader of the record.** Anyone reading the repository later. Every turn
  an agent takes leaves its account there, and the completeness of that account
  is now something the agents provide rather than something the supervisor
  guaranteed.

## Goals

1. A goal filed by the operator is worked without anything else being typed.
2. Several roles work in the same wall-clock window because each decides for
   itself, not because a scheduler interleaved them.
3. A task is worked exactly once at a time, whatever two capable agents do
   simultaneously.
4. An agent that dies does not take its task with it.
5. The factory keeps working when the operator is not there, and stopping it
   loses nothing.
6. The operator can speak to a working agent and redirect it without waiting for
   it to finish.
7. Nothing outside a cage ever has to read what an agent wrote in order to
   decide what happens next.

## Non-goals

- **A dispatcher.** Nothing outside a cage decides what is worked next. This is
  the reversal of PRD-002 and the reason it is superseded rather than built.
- **An agent starting another agent.** A role files work for a capability, and
  the agent that provides it takes that work when it next reads the record. No
  role starts another role's loop or interrupts its turn.
- **A timer.** Nothing files work on a schedule. What enters the record is put
  there by the operator or by a role along the graph the factory declares, which
  is what keeps the queue a real bound.
- **Priority or preemption.** Tasks are not ranked and a turn in progress is not
  taken away. If ordering turns out to matter, it is a later decision.
- **Proving authorship against a hostile role.** Every role can write the
  record, including entries attributed to another. The record is an accurate
  account of agents that are not lying, and is not evidence.
- **Publication.** No agent pushes to any remote, unchanged from PRD-003.
- **Agent-edited declarations.** Which roles exist and what they may do stays the
  operator's, now by way of the repository's own declaration (ADR-020).
- **Cross-factory work.** An agent addresses its own factory's record. Reaching
  another is PRD-001's territory and nothing here waits on it.

## Success criteria

- The operator files one goal, types nothing else, and the work is taken,
  worked and accounted for in the record within a poll interval and a turn.
- Two capable agents and one task, run many times over, produce exactly one
  worker every time and never two.
- An agent is killed in the middle of a turn, and its task is picked up and
  finished by a peer within the lease period, with both attempts visible in the
  record.
- The operator leaves for a night. In the morning the factory has advanced, and
  stopping the machine has left no truncated worktree, ref or record entry.
- The operator attaches to a working agent, redirects it, detaches, and the
  agent is still working when they come back.
- A workflow that has spent its budget stops taking turns without anyone
  intervening.
- Nothing outside a cage opens a task body, a comment or a document. This is
  structural after phase 5, because the supervisor is left with no decision that
  would need one.

These say it works. These say whether it should be kept, and are answerable from
the record and from git:

- Over a month, the share of merged work that an agent took on its own initiative
  rather than being pointed at. If it stays near zero, the loop is a costume over
  the operator still deciding everything.
- Spend per merged task, tracked against what the same work cost when a person
  started every turn. An always-on factory that costs more per result is a worse
  factory that feels busier.
- Turns wasted on work that was stolen, duplicated or redone. This is the price
  of the lease, and it has to stay small enough to be worth what the lease buys.
- Interventions per merged task. Falling means the agents are getting the work;
  holding steady means the operator is still doing it through a slower interface.

## Requirements

### The record

- A task lives in one place, in the repository, and carries everything about it:
  its state, its stage, its workflow, the fields a stage requires, and its
  discussion. There is no second store to join against and no state that exists
  only outside the repository.
- An agent finds what it may take from metadata alone, so finding work never
  depends on parsing what another agent wrote.
- An agent writes the record as itself, from inside its own cage, while its peers
  are doing the same in the same clone. Two agents writing different tasks never
  interfere; two writing one task both land.
- Every entry says which role made it. That attribution is correct for agents
  behaving normally and is not proof against one that is not.

### Taking work

- A task naming a capability is visible to every role that provides it, and
  exactly one of them ends up working it, whatever the timing.
- An agent that fails to take a task learns so immediately and goes back to
  reading, rather than waiting on anything.
- A hold on a task lapses if the holder stops maintaining it, so a crash, a
  stopped machine or a closed laptop returns the work to the pool rather than
  stranding it.
- Work taken over from a lapsed hold continues from where the previous holder
  reached rather than starting again, and the record shows that it changed hands.
- A hold released or taken over is done against the value it actually had, so two
  agents cannot both believe they hold one task.

### The loop

- Each role has one agent, running from when the factory starts until it is
  stopped, whether or not anyone is connected to it.
- An agent works only what its role provides and only what is in the record.
- An agent stops taking turns when its workflow's budget is spent, and says so
  where the operator will see it.
- An agent with nothing to take costs the factory nothing but the reading.

### The console and intervention

- The operator can reach a working agent, see what it is doing and speak to it,
  and leaving does not stop it.
- Reaching an agent grants it nothing. It signs with its own key and has no path
  to a remote, whether or not somebody is watching.

### Stopping

- A factory can be stopped without losing a turn's work, a record entry or a
  worktree, and the holds its agents had do not outlive them in a way that
  strands their tasks.
- An agent can be stopped on its own, and its peers keep working.

## Constraints

- The factory's clone uses git's files ref backend, because the permission model
  is POSIX ACLs on ref directories and there is no directory to name otherwise.
- Labels carry no colon, because git-bug's query parser does not survive one.
- All roles share one clone and one object database, as ADR-011 has it.
- An agent holds a signing key and no forwarded agent (ADR-009), before and
  during any intervention.
- git-bug 0.10.1 is the record, driven for real by the suite rather than stubbed.
- One host, one operator, one repository per factory.

## Risks

- **The budget is enforced by the thing it bounds.** An agent checks its own
  remaining budget. A broken or dishonest one is bounded only by the machine's
  resources and by the operator noticing. This is accepted in ADR-021 and it is
  the largest thing given up here.
- **A hung agent looks alive.** Maintaining a hold is separate from doing the
  work, so an agent whose process is up but making no progress keeps its task
  indefinitely. Nothing in the design detects this, and the operator does.
- **Losing work to a premature takeover.** If a hold lapses while its holder is
  still working, two agents do one task and one of them wastes a turn. This is
  the failure the model exists to rule out, and the one to watch in the first
  weeks of use.
- **Intervention leaves no trace.** Words typed into a running agent change what
  it does and are not in the record, so the record stops being a complete account
  of why the work looks as it does.
- **Overnight spend.** An always-on factory spends while nobody is watching. The
  bounds that hold regardless are the machine's, and the operator finds out the
  rest by looking.
- **Agents can rewrite each other's history.** Opening the record to every role
  means opening all of it. Nothing in the design relies on the stronger property,
  and losing it should be noticed rather than discovered.

## Open questions

- **How often is often enough?** The poll interval trades latency against
  constant reading, and whether it backs off when the record is quiet is not
  decided.
- **How long is a hold good for?** Long enough to survive a slow turn, short
  enough that a dead agent's work returns quickly. Those pull opposite ways and
  no number is chosen here.
- **Which task first?** An agent seeing several takeable tasks has no stated rule
  for choosing between them, and oldest-first, cheapest-first and
  furthest-along-first are all defensible.
- **Does an intervention cost a turn?** Whether words typed into a running agent
  count against a workflow's budget is not settled, and it decides whether an
  operator can talk a factory out of its budget.
- **Who sweeps abandoned holds?** A task cancelled while held leaves a hold
  nobody will release. That is the one piece of taking that stays outside the
  cages, and where it belongs is open.
- **What does a role do when its only work is blocked?** An agent whose queue
  holds nothing takeable idles. Whether it should instead say so, or ask, is not
  decided.

## Phases

Ordered so the record moves before anything reads it concurrently, taking is
correct before anything takes without being asked, and the loop exists before a
console attaches to one.

1. **The record holds the task.** Tasks become issues, state becomes labels,
   the record opens to every role, and each role writes as itself from its own
   worktree. The old file store and its tests are deleted here, because this is
   the phase that replaces them. Nothing loops yet: a person still starts a turn,
   and it reads and writes the new store.
2. **Taking is a claim.** The compare-and-swap, the lease, its renewal, its
   expiry and the takeover. Modeled and checked before it is written, because
   this is the phase where two things can be wrong at once. Still no loop: taking
   happens inside a turn a person starts, and two turns started at once cannot
   collide.
3. **The loop.** The agent service, one per role, polling and taking and working
   and recording, checking its own budget and stopping when it is spent. The
   phase where the factory starts moving without being pushed, and the first one
   whose value is visible over a night rather than a command.
4. **The console.** Attaching to a working agent, watching it, speaking to it,
   and leaving without ending it. Sequenced after the loop because there is
   nothing to attach to before it.
5. **Stopping, and what is left of the supervisor.** Stopping a factory and a
   single agent cleanly, holds that do not outlive their holders, the sweep for
   the ones that do, and the supervisor reduced to preparing a role, advancing
   the shared branch and syncing with the operator's checkout.

## Design gates

The Formal Modeling Gate fires on taking a task, and `models/task-claim.qnt` is
written and run before phase 2 is implemented. It is a lease handoff between
processes in separate cages with a compare-and-swap and an expiry, over several
capable agents, one record and a clock that may expire a hold at any point
including during a turn. Two invariants: no two agents ever hold one task, and no
takeable task stays unclaimed forever.

`models/factory-structure.als` changes in the same commit as phase 1, because
what a role may write changes: the record and the claims are writable by all
roles, where its ref model has each role writing only its own namespace.

`models/factory-lifecycle.qnt` is revisited in phase 3 rather than assumed
intact. It describes a task and run lifecycle whose transitions were driven by
one supervisor, and the transitions are now driven by whichever agent holds the
task.
