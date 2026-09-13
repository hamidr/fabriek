---
name: tdd
description: Write the failing test first, watch it fail for the right reason, make it pass with the least code, refactor green. Use for every behaviour you add or change, including a bug fix.
---

# Test first

No production code without a failing test that asks for it. A test
written after the code passes on the first run and proves nothing.

## The cycle

1. **Red.** One test, one behaviour, named as the sentence that would be
   false if the code were missing: `refuses an invoice with no lines`.
   Run it. It must fail, and fail because the behaviour is absent, not
   because of a typo or a missing import. A test that errors is not red.
2. **Green.** The least code that makes it pass. No second feature, no
   option nobody asked for, no refactor of neighbours.
3. **Refactor.** Names, duplication, seams, while green. Run the suite
   after each step.
4. Commit red and green together, one behaviour per commit, so the
   reviewer sees the test before the code in the same diff.

## A bug

A bug is a missing test. Reproduce it as a failing test first; the fix is
the green step. A fix without that test is not accepted.

## What a test looks like

- One behaviour; an "and" in the name means two tests.
- Real code; a fake only at a boundary (network, clock, filesystem), and
  the fake's behaviour is asserted by the test that owns the boundary.
- Given, when, then, in that order, in the body.
- Reads as the specification: someone who deletes the code could rewrite
  it from the test names.

## Before reporting done

The suite of the module you touched ran after your last edit and passed.
Say so in the outcome with the command and the count. A run you did not
do is a claim the reviewer will make you do.
