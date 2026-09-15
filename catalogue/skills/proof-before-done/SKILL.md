---
name: proof-before-done
description: Run the command that proves a claim and read its output before making it. Use before report_outcome with done, before a commit, and before any sentence saying tests pass, the build is green or a bug is fixed.
---

# Proof before done

A claim without a fresh run is a claim, and the executor and the
reviewer treat it as one. Evidence first, then the sentence.

## The gate

Before saying any of "passes", "fixed", "builds", "done":

1. Name the command that would prove it.
2. Run it, whole, now. Not an earlier run; not a subset.
3. Read the whole output: the exit code, the count of failures, the
   last lines.
4. Does it show the claim? If not, report what it shows instead. If
   yes, the claim goes in your outcome with the evidence beside it: the
   command and the line that proves it.

Skipping a step is not verifying; it is asserting.

| Claim | What proves it | What does not |
| --- | --- | --- |
| tests pass | the runner's output, zero failures, this run | an earlier run, "should pass" |
| lint clean | the linter's output, zero problems | a partial file list |
| builds | the build's exit 0 | the linter passing |
| bug fixed | the reproduction that failed now passes | the code changed |
| regression test works | seen failing without the fix, passing with it | passing once |
| task done | the task's finish line, item by item | tests passing |

## Words that mean stop

"should", "probably", "seems to", "looks right"; any satisfaction
before the run; a commit or a `done` about to be reported without the
run in this session. Tired is not an exemption, and neither is "just
this once".

## In the outcome

`done` with the command and the decisive line of its output. If a check
was not run, say which and why, and report `failed` or `blocked` rather
than `done`: the executor takes `done` only with a commit, and the
reviewer runs the tests again either way. A `done` the reviewer
overturns costs the factory a full cycle; a `failed` with evidence
costs one line.

Derived from the verification-before-completion skill of superpowers
(github.com/obra/superpowers, MIT), cut to what a role in a cage can do.
