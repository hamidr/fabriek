---
name: debugging
description: Find the cause before touching a fix. Use on any test failure, bug, build failure or behaviour you did not expect, before proposing a change; use it most when a quick fix looks obvious, when a fix already failed, or when the task says hurry.
---

# Debugging

No fix without a cause. A change made to see whether the symptom goes
away is a guess, and a guess that works hides the cause under it.

## 1. Cause

Before any change:

- Read the whole error: the message, the trace, the file and line, the
  exit code. It names the place more often than not.
- Reproduce it. The exact command, the exact input, every time. What
  will not reproduce is not understood; gather more before guessing.
- Read what changed: `git log` and `git diff` since it last worked, a
  dependency, a setting, the environment.
- Across components (a build that feeds a script that feeds a service),
  print what enters and leaves each boundary, run once, and read where
  the value goes wrong. Then look only there.
- Deep in a stack, trace the bad value backwards: what produced it, what
  called that with it, until the source. The fix goes at the source.

## 2. Pattern

Find the nearest working thing: the same call elsewhere in this tree,
or the reference the code follows. Read it whole, not skimmed. List
every difference between it and the broken one, including the ones
that "cannot matter". Name what the broken one depends on: settings,
order, state, environment.

## 3. One hypothesis

Write it in one sentence: "X is the cause because Y." Test it with the
smallest change that would confirm it, one variable at a time. If it
holds, go to 4. If not, a new sentence; never a second change on top of
the first. When you do not understand something, say which thing, in
your outcome if you cannot get past it; do not pretend.

## 4. Fix

- First the failing test that shows the cause, as the tdd skill says:
  the simplest reproduction, automated where the repository has a
  runner. The loop's guard refuses an edit before it anyway.
- One fix, for the cause. Nothing else "while here".
- Run the test, then the tests around what you touched. The
  proof-before-done skill says what counts as having run them.

## Stop

After two fixes that did not hold, stop. A third variation is a guess.
If each fix uncovers a new problem in a new place, the shape is wrong
and not the line: report `blocked` with the two hypotheses ruled out,
what the trace showed, and what a decision from the architect or the
operator would change. That is a result; a fourth attempt is not.

Thoughts that mean stop and go back to 1: "quick fix now, look later",
"try changing X and see", "several changes then run the tests", "it is
probably X", "I do not fully understand but this might work".

Derived from the systematic-debugging skill of superpowers
(github.com/obra/superpowers, MIT), cut to what a role in a cage can do.
