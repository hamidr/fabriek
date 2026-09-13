// What a thread says about attempts: an attempt line is the executor's and
// names its stage, so a task's second stage begins at attempt 1 and a budget
// of two attempts is two per stage, whichever role serves it.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { attemptLine, attemptsAt, tipOf } from "./thread.js";

const thread = [
  { by: "executor", body: "attempt 1 started for builder at build (branch at abc)" },
  { by: "builder", body: "outcome: failed\n\nno" },
  { by: "executor", body: "attempt 2 started for builder at build (branch at abc)\n\nprevious outcome:\noutcome: failed" },
  { by: "builder", body: "outcome: done\n\nyes" },
  { by: "executor", body: "attempt 1 started for builder at test (branch at def)" },
  { by: "reviewer", body: "attempt 9 started for reviewer at review (branch at none)" },
];

describe("a thread's attempts", () => {
  it("counts the executor's attempt lines at the stage named, and nobody else's", () => {
    assert.equal(attemptsAt(thread, "build"), 2);
    assert.equal(attemptsAt(thread, "test"), 1);
    assert.equal(attemptsAt(thread, "review"), 0);
  });

  it("writes an attempt line with the stage and the branch's tip, and reads the tip back, none meaning no branch", () => {
    assert.equal(attemptLine(1, "builder", "build", "abc"), "attempt 1 started for builder at build (branch at abc)");
    assert.equal(tipOf("attempt 1 started for builder at build (branch at abc)"), "abc");
    assert.equal(tipOf("attempt 1 started for builder at build (branch at none)"), null);
    assert.equal(tipOf("outcome: done"), null);
  });
});
