---
name: review-findings
description: Work a reviewer's findings on a retried task. Use when the brief's previous outcome is a reviewer's blocked with one finding per line, before changing anything: verify each against the tree, order them, fix one at a time behind its test, and say in the outcome which you refused and why.
---

# Working a reviewer's findings

A finding is a claim about the tree, made by a role that read the diff
and ran the tests. Claims are checked, not obeyed and not argued with.

## Read all, then verify each

1. Read every finding before touching one. Findings are related; a fix
   for the third can undo the first.
2. For each: restate it as what would have to change, by path and line.
   A finding you cannot restate you cannot fix; it goes in the outcome
   as unclear, with the line quoted, and the task is `blocked` if
   nothing else can be done without it.
3. Check it against the tree: is it right for this code, does the
   change break what works, is there a reason the code is as it is
   (a test that pins it, a caller, a platform), does the reviewer see
   the whole of it? `git log -S` and the tests around the line answer
   most of this.
4. A finding that is wrong for this tree is refused in the outcome with
   the reason and the evidence: the test that pins the behaviour, the
   caller that needs it, the record that decided it. Refused, not
   ignored; the reviewer reads the outcome.
5. A finding that asks for a feature the tree does not use: grep for a
   caller. None: the answer is to remove, not to complete. Say so.

## Then fix, in this order

Blocking first (broken, unsafe, untested), simple next (names, imports,
a missing case), complex last (a unit moved, logic changed). One at a
time, each behind its test as the tdd skill says, the suite run after
each; the proof-before-done skill before the outcome.

## What the outcome says

Per finding, one line: `fixed <path:line>: <what changed>`, or
`refused <path:line>: <why, with evidence>`, or `unclear: <quoted>`.
No thanks, no agreement, no apology; a fix is the acknowledgement, a
refusal is the disagreement, and a refusal you later found wrong is one
line saying what you checked and what it showed.

## What not to do

- Fix the ones you understood and leave the rest for later: partial
  understanding is wrong implementation.
- Fix several at once and run the tests at the end: nothing then says
  which fix broke what.
- Take a finding on the reviewer's word when the tree can be asked.
- Change a decision the architect recorded because a finding asks: the
  record wins; say so and mention the architect.

Derived from the receiving-code-review skill of superpowers
(github.com/obra/superpowers, MIT), cut to what a role in a cage can do.
