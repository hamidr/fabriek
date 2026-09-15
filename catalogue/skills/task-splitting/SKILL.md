---
name: task-splitting
description: Split a goal into tasks a builder can take without asking, each with what it changes, what done means, what it must not touch, what it waits on, and the names it shares with its neighbours. Use at the plan stage, with the architect's record beside the goal, before writing the outcome that lists the tasks.
---

# Splitting a goal into tasks

The reader of a task is a builder with a fresh session: skilled, with
no memory of this thread, seeing only its own task. Write for that
reader. The decider files what your outcome lists and hands each task
to a role; nobody fills a gap you left.

## Before the split

- Read the architect's record for this goal. Every decision a builder
  would otherwise have to make is in it, or the goal is not ready: ask
  for the record, not for an answer, and report `blocked` naming what
  is missing.
- Read the tree: which files each part of the goal touches, where the
  existing seam is. A task names its files.
- If the goal is several independent things, it is several goals: say
  so in your outcome and split the first; a task list that mixes them
  is filed as one and worked as none.

## The size of a task

A task is the smallest unit that carries its own test cycle and is
worth a reviewer's verdict on its own. Fold setup, configuration and
documentation into the task whose deliverable needs them; split only
where a reviewer could refuse one task and accept its neighbour. Each
task ends in something that runs and is tested by itself.

## One task, one line of your outcome

Each line carries, in this order:

- **changes**: the files it creates or modifies, by path, and the unit
  in each.
- **done means**: what passes when it is done, as the command and the
  behaviour; never "tests for the above".
- **must not touch**: what stays as it is, by path or by name, so a
  builder that finds it tempting knows it was seen and refused.
- **waits on**: the tasks before it, by their line, or none.
- **shares**: the names it consumes from earlier tasks and produces for
  later ones, with signatures; a builder sees only its own task, and
  this is how the names agree across tasks.

Example:

```
1. changes: src/importer.py (parse_row, import_file); tests/test_importer.py.
   done means: pytest tests/test_importer.py passes with empty, BOM and
   malformed rows covered. must not touch: src/api/. waits on: none.
   shares: produces parse_row(line: str) -> Row | None.
2. changes: src/api/upload.py (post_upload). done means: pytest
   tests/test_upload.py passes; a 400 on a malformed file. must not
   touch: src/importer.py. waits on: 1. shares: consumes parse_row.
```

## What may not appear

"TBD", "later", "as appropriate", "handle edge cases", "similar to
task N", "add tests": each is a decision handed to a builder who
cannot make it. A name no task defines. A file that does not exist and
no task creates.

## Before you report

Read the record again against the list: every requirement points at a
task, or a task is missing. Every name used in a later task is produced
by an earlier one, spelled the same. Then the outcome: `done`, the
list, and the record it was split from.

Derived from the writing-plans skill of superpowers
(github.com/obra/superpowers, MIT), cut to what a role in a cage can do.
