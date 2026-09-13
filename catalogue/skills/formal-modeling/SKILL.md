---
name: formal-modeling
description: Check a design for counterexamples with Quint or Alloy 6 before it is built - a protocol, a state machine, a permission or ownership model, a cross-entity invariant. Covers picking the tool, writing the model under models/, running it in this cage, and reporting the verdict with its bound.
---

# Formal modeling

The goal is a counterexample, not a proof. A model that finds one bad
interleaving before a builder writes the code has paid for itself.

## When

Before a design that is any of: a concurrent or distributed protocol; a
state machine with more than three states whose transitions interleave
across a process, thread or network boundary; a permission, authorization
or ownership model; an invariant spanning more than one entity; a
scheduling, allocation or resolution problem. Everything else is exempt:
no models of CRUD, glue or straight-line transforms. A listed shape that
does not warrant a model gets one sentence in the record saying why.

## Pick the tool

| Question | Tool | Verdict |
|---|---|---|
| Can this sequence of events ever reach a bad state? | Quint | a trace to the violating state |
| Is any legal configuration of this structure broken? | Alloy 6 | an instance that breaks the assertion |

Time and interleaving ("eventually", "concurrently", "retry", "crash",
"out of order") means Quint. Shape and relationship ("every", "exactly
one", "cannot both", "reachable", "cycle") means Alloy. Alloy is usually
the cheaper to write.

## Where

`models/<name>.qnt` or `models/<name>.als` in the repository, committed
with the record that cites it. The file opens with a comment naming the
code it constrains, so a reader can tell when it went stale. When the
invariant changes, the model changes in the same commit as the code.

## Quint

State variables, `init`, a `step` that nondeterministically picks a
transition, named invariants.

```quint
module lock {
  pure val procs = Set("p1", "p2", "p3")
  var holder: str
  var waiting: Set[str]
  action init = all { holder' = "", waiting' = procs }
  action acquire(p) = all {
    holder == "", waiting.contains(p),
    holder' = p, waiting' = waiting.exclude(Set(p)),
  }
  action release(p) = all {
    holder == p, holder' = "", waiting' = waiting.union(Set(p)),
  }
  action step = nondet p = procs.oneOf() { any { acquire(p), release(p) } }
  val holderNeverWaits = not(waiting.contains(holder))
}
```

```sh
quint typecheck models/lock.qnt
quint run models/lock.qnt --invariant=holderNeverWaits --max-steps=30 --max-samples=10000
```

`quint run` is a randomized simulator: fast, finds shallow bugs, proves
nothing. It prints a violating trace or `[ok] No violation found` with the
samples it took. Report the steps and samples, never "it passed". Read a
trace as states: each `[State n]` is the full assignment after one
transition; the bug is the transition between the last good state and the
first bad one.

`quint verify` needs Apalache, which this cage cannot fetch. Do not reach
for it; say in the record that the verdict is simulation up to the bound.

## Alloy 6

Signatures for entities, fields for relations, `fact` for what the
implementation guarantees, `assert` for what must hold, `check` to hunt.

```alloy
sig User {}
abstract sig Role { members: set User }
one sig Admin, Guest extends Role {}
fact RolesAreExclusive { no Admin.members & Guest.members }
assert AdminsAreNotGuests {
  all u: User | u in Admin.members implies u not in Guest.members
}
check AdminsAreNotGuests for 5
```

```sh
alloy6 exec models/roles.als
```

One line per command: `00. check AdminsAreNotGuests 0 UNSAT`.

Read the verdict backwards. For a `check`, `UNSAT` is good: no
counterexample within the scope. `SAT` means Alloy found one and the
assertion is false. For a `run`, `SAT` means the configuration is
possible. Always report the scope: `UNSAT for 5` says nothing about 6.
Raise it until the check gets slow.

## Before trusting a pass

Break the model on purpose: delete a `fact`, drop a guard, and confirm
the checker turns red. An invariant that never fails is usually vacuous.
Concurrency bugs often need three participants; two is where symmetry
hides them.

## Report

In the record, four lines: the tool and the model path; the exact command;
the verdict with its bound (scope, or steps and samples); what changed in
the design because of it, or "the model found nothing, the design stands".
A model written and not run is not a result.
