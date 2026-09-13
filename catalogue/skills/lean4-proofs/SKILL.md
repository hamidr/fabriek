---
name: lean4-proofs
description: Prove a theorem about an algorithm or a data structure in Lean 4, in a plain file with core Lean and no mathlib, and check its axioms before calling it proved. Use when "no counterexample up to N" is not a strong enough answer.
---

# Lean 4 proofs

Lean proves a statement for all inputs. Quint and Alloy hunt for a
counterexample up to a bound. One does not substitute for the other: a
model run does not prove a theorem, and a proof does not discharge the
modeling gate. Reach for Lean when the record needs "always", not "not
found up to 5".

## A plain file, no project

No `lake`, no mathlib: this cage cannot fetch either, and core Lean covers
logic, arithmetic and reasoning about algorithms over the core types.

```sh
lean models/insert.lean
```

```lean
-- Constrains: src/sort/insert.py, the insertion step.
def insert' (a : Nat) : List Nat -> List Nat
  | [] => [a]
  | b :: bs => if a <= b then a :: b :: bs else b :: insert' a bs

theorem length_insert' (a : Nat) (l : List Nat) :
    (insert' a l).length = l.length + 1 := by
  induction l with
  | nil => rfl
  | cons b bs ih => simp only [insert']; split; rfl; simp [ih]

theorem arith (x y : Nat) (h : x + 2 <= y) : x < y := by omega

#print axioms length_insert'
#print axioms arith
```

Write ASCII operator names. `not`, `or`, `and` are the `Bool` functions,
so `not (p or q)` on a `Prop` fails with `Function expected`. The
propositional forms are `Not`, `Or`, `And`, `Iff`; `<->` and `->` are the
arrows.

## Where

`models/<name>.lean`, beside the Quint and Alloy models, opening with a
comment naming the code it is about. Cited from the record that needed it.

## Always check the axioms

A proof containing `sorry` succeeds: a warning, exit 0. Only the axiom
list shows the hole.

```
'bad' depends on axioms: [sorryAx]
```

Run `#print axioms <name>` for every theorem and read it before reporting
the proof done. A complete proof lists none, or a subset of `propext`,
`Classical.choice`, `Quot.sound`. `sorryAx` means not proved.

## Report

In the record: the file, the command, each theorem with its axiom list,
and what the theorem lets the design assume.
