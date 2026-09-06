---
id: ADR-021
title: A role's agent is a loop that takes its own work
status: accepted
date: 2026-09-06
status_date: 2026-09-06
summary: each role runs a long-lived agent that polls the record and takes its own work, bounded by its queue not by dispatch
depends_on: [ADR-009, ADR-010, ADR-016]
supersedes: []
superseded_by: []
---

## Context

PRD-003 made one property structural rather than observed: no run is ever
started by a cage, because no cage holds the program that starts one. The
operator types `cageworks task run`, and nothing else in the system can. It is
a strong property and it was cheap, because dispatch was the only autonomy
anyone wanted to withhold.

It costs the factory its point. A team of specialists that advances only when a
person types a command advances at the speed of that person's attention, and the
whole argument for several roles working one repository was that attention is
the scarce thing.

PRD-002's answer was an uncaged supervisor that dispatches. Examined again, it
fails on the invariant it was built beside. Choosing what to work next is
reading the work: which of three open tasks is worth a turn, whether a stage's
`done` has been met, whether a blocked task can move. The supervisor is
content-blind by design, so it can only dispatch on labels and shapes, and every
improvement to its choosing pushes it toward reading agent-authored text, which
PRD-002 itself names as its top risk. ADR-015 already conceded this shape for
one field: `done` is prose handed to the role and never checked, because judging
whether work meets a bar is reading content and belongs in a cage. Choosing what
to work next is the same act.

The alternative is to put the choosing where the reading is allowed.

## Decision

**1. A role's agent is a long-lived service in the guest.** One per role,
started with the factory, running until it is stopped. It is not a session
somebody opened, and closing the operator's terminal does not end it.

**2. It takes its own work.** The loop reads the record, finds what it is
capable of and may take, takes it, does the turn, records the outcome, and reads
again. Taking is ADR-023's business; this document decides only that the taker
is the agent.

**3. It polls on an interval.** Simple, identical on both platforms, and a
latency floor rather than a missed wake-up. Every role's agent reads one clone,
so the cost is git reads against a working tree already on local storage.

**4. Its queue is what bounds it.** An agent works only what is in the record,
and what is in the record was put there by the operator or by another role along
the graph the factory declares. The loop is unbounded in time and bounded in
material: an empty queue is an idle agent. This is weaker than the property it
replaces, and the weakness is the price of point 2.

**5. It checks its own budget.** A workflow's remaining budget is read before a
turn and the agent stops when it is spent. A cage now enforces its own cap,
which is a real loss: the count is only as good as the agent honouring it. What
still holds from outside are the resource bounds, since the role's worktree
quota and the machine's cores and memory are facts about the machine rather than
promises by the agent.

**6. herdr attaches to a running agent rather than starting one.** The agent has
a console in the guest that an operator can join and leave without ending it.
Typing into it speaks to the agent mid-turn, which is how an operator directs a
commit or intervenes.

**7. Attaching lends the agent nothing.** ADR-009 is unchanged: the agent holds
its own signing key and has no forwarded agent, so it can sign and cannot push,
pull a private repository, or authenticate anywhere. An operator watching over
its shoulder does not become its credentials.

**8. What is left of the supervisor.** Preparing a role, advancing `main`, and
syncing with the operator's checkout. It does not dispatch, does not resolve who
takes what, and after ADR-022 does not write the record either. Its
content-blindness stops being an invariant anyone has to maintain, because it
now reads nothing at all.

## Consequences

The property PRD-003 was proudest of is gone, and nothing structural replaces
it. A cage starts its own runs and counts its own budget. What remains outside
every cage is the machine, `main`, and the operator: a role still cannot write
another role's refs, cannot advance the shared branch, and cannot reach a
remote. An agent that decides to work forever is stopped by a person, or by
running out of quota, and not by arithmetic it agreed to.

Cost becomes continuous rather than per command. A factory left running spends
whatever its agents spend, and the operator finds out by looking.

A console that survives detaching has to be built. herdr runs on the operator's
machine and the agent runs in the guest, so the pane holds a connection to a
terminal the agent owns, not the agent's own process.

Intervention is not in the record. Words typed into a pane change what an agent
does and leave no trace in git, so a task's thread stops being a complete
account of why the work looks as it does. Filing a task instead would be
recorded and slower; both are wanted, and this document chooses the immediate
one and states what it costs.

The Formal Modeling Gate fires, and is discharged in ADR-023, where the
concurrent protocol actually lives. This document adds no interleaving of its
own: one agent per role, each reading and acting in sequence.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
```

The loop's bound is what the suite asserts, since the loop itself is a service:
an agent offered a task outside what its role provides does not take it, an
agent whose workflow budget is spent stops rather than taking another turn, and
an agent whose console is detached from is still running when it is attached to
again.
