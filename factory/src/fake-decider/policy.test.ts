// What the scripted decider asks for: every task at a stage with nobody on
// it goes to a ready role that provides the stage, one task per role per
// round, and nothing else is ever asked.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readDeclaration } from "../declaration.js";
import { decide } from "./policy.js";

const declaration = readDeclaration(
  JSON.stringify({
    name: "acme",
    roles: { builder: { command: ["pi"], provides: ["build"] }, reviewer: { command: ["pi"], provides: ["review"] }, tester: { command: ["pi"], provides: ["build"] } },
    workflows: { ship: { stages: [{ needs: "build" }, { needs: "review" }] } },
    resources: { taskAttempts: 2 },
  }),
);

const issue = (n: number, stage: string | null, extra: Partial<{ assignee: string | null; attempts: number; blocked: boolean }> = {}) => ({
  number: n,
  title: `t${n}`,
  stage,
  assignee: null,
  attempts: 0,
  blocked: false,
  lastOutcome: null,
  ...extra,
});

describe("the scripted decider's policy", () => {
  it("given unassigned tasks at stages and ready roles, then each goes to a ready role providing its stage, one per role", () => {
    const out = decide({ issues: [issue(1, "build"), issue(2, "build"), issue(3, "review")], ready: ["builder", "reviewer", "tester"], routing: true }, declaration);
    assert.deepEqual(out, [
      { verb: "assign", issue: 1, role: "builder" },
      { verb: "assign", issue: 2, role: "tester" },
      { verb: "assign", issue: 3, role: "reviewer" },
    ]);
  });

  it("given a task that is assigned, blocked, past its attempts or at no stage, then it is left alone", () => {
    const out = decide(
      { issues: [issue(1, "build", { assignee: "builder" }), issue(2, "build", { blocked: true }), issue(3, "build", { attempts: 2 }), issue(4, null)], ready: ["builder", "tester"], routing: true },
      declaration,
    );
    assert.deepEqual(out, []);
  });

  it("given routing stopped, then nothing is asked", () => {
    assert.deepEqual(decide({ issues: [issue(1, "build")], ready: ["builder"], routing: false }, declaration), []);
  });
});
