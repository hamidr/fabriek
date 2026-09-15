// The decider (ADR-034 points 1 and 5): a caged actor that reads the board,
// the ready set, the declaration and one policy file the repository names,
// and asks the executor for things in the six verbs. It writes nothing but
// commands, and a command that is not in the vocabulary never reaches the
// bus. Driven against fakes: what is asserted is the prompt's four parts and
// the gate on the way out.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Decider, type Commands, type Snapshot } from "./core.js";
import { readDeclaration } from "../declaration.js";

const declaration = readDeclaration(
  JSON.stringify({
    name: "acme",
    roles: { builder: { command: ["pi"], provides: ["build"] }, reviewer: { command: ["pi"], provides: ["review"] } },
    workflows: { ship: { stages: [{ needs: "build", done: "tests pass" }, { needs: "review" }] } },
    resources: { taskAttempts: 3 },
  }),
);

const snapshot: Snapshot = {
  issues: [
    { number: 7, title: "Add importer", stage: "build", assignee: null, attempts: 1, blocked: false, lastOutcome: "outcome: failed\n\ntests would not compile" },
    { number: 8, title: "Review the importer", stage: "review", assignee: "reviewer", attempts: 1, blocked: false, lastOutcome: null },
  ],
  ready: ["builder"],
  routing: true,
};

function fakes() {
  const written: unknown[] = [];
  const commands: Commands = { async send(c) { written.push(c); } };
  return { commands, written };
}

describe("the decider", () => {
  it("its prompt has the machine's rules, the declaration as data, the board with the ready set, and the repository's policy, labelled", () => {
    const d = new Decider({ declaration, policy: "Prefer finishing started work over starting new work.", commands: fakes().commands });
    const prompt = d.prompt(snapshot);
    assert.ok(prompt.indexOf("# Rules") < prompt.indexOf("# Declaration"));
    assert.ok(prompt.indexOf("# Declaration") < prompt.indexOf("# Board"));
    assert.ok(prompt.indexOf("# Board") < prompt.indexOf("# Policy"));
    for (const piece of ["assign", "retry", "block", "file", "push", "stop", "builder", "review", "tests pass", "#7", "Add importer", "attempts: 1", "tests would not compile", "ready: builder", "Prefer finishing"]) {
      assert.ok(prompt.includes(piece), `prompt carries ${piece}`);
    }
  });

  // ADR-055: the decider is told the ceiling on tasks in flight, so it does
  // not ask for what the executor will refuse.
  it("the prompt says how many tasks may be in flight, or that every role may hold one", () => {
    const capped = readDeclaration(JSON.stringify({ ...JSON.parse(JSON.stringify(declaration)), resources: { taskAttempts: 3, concurrency: 1 } }));
    assert.match(new Decider({ declaration: capped, policy: null, commands: fakes().commands }).prompt(snapshot), /^tasks in flight at once: 1$/m);
    assert.match(new Decider({ declaration, policy: null, commands: fakes().commands }).prompt(snapshot), /^tasks in flight at once: one per role$/m);
    assert.match(new Decider({ declaration, policy: null, commands: fakes().commands }).prompt(snapshot), /in flight/);
  });

  it("without a policy file, the prompt says so rather than leaving the section out", () => {
    const d = new Decider({ declaration, policy: null, commands: fakes().commands });
    assert.match(d.prompt(snapshot), /# Policy\n\(the repository declares none\)/);
  });

  it("the prompt says when routing is stopped, so the model does not keep asking", () => {
    const d = new Decider({ declaration, policy: null, commands: fakes().commands });
    assert.match(d.prompt({ ...snapshot, routing: false }), /soft limit/);
  });

  it("a valid command from the model is written to the bus as it was said", async () => {
    const f = fakes();
    const d = new Decider({ declaration, policy: null, commands: f.commands });
    const r = await d.command({ verb: "assign", issue: 7, role: "builder" });
    assert.equal(r.ok, true);
    assert.deepEqual(f.written, [{ verb: "assign", issue: 7, role: "builder" }]);
  });

  it("a command outside the vocabulary is refused here and never written, and the refusal tells the model why", async () => {
    const f = fakes();
    const d = new Decider({ declaration, policy: null, commands: f.commands });
    const r = await d.command({ verb: "merge", issue: 7 });
    assert.equal(r.ok, false);
    assert.match(r.ok ? "" : r.reason, /merge/);
    assert.deepEqual(f.written, []);
  });

  it("a command the declaration cannot accept is refused here too, before the executor ever sees it", async () => {
    const f = fakes();
    const d = new Decider({ declaration, policy: null, commands: f.commands });
    let r = await d.command({ verb: "assign", issue: 7, role: "ghost" });
    assert.match(r.ok ? "" : r.reason, /ghost/);
    r = await d.command({ verb: "file", titleFile: "/t", bodyFile: "/b", stage: "deploy" });
    assert.match(r.ok ? "" : r.reason, /deploy/);
    assert.deepEqual(f.written, []);
  });

  it("the board is rendered from issues and the ready set, and a blocked issue says what it waits on", () => {
    const d = new Decider({ declaration, policy: null, commands: fakes().commands });
    const prompt = d.prompt({
      issues: [{ number: 9, title: "x", stage: "build", assignee: "builder", attempts: 2, blocked: true, lastOutcome: "outcome: blocked\n\nneeds #7" }],
      ready: [],
      routing: true,
    });
    assert.match(prompt, /#9 .*blocked/);
    assert.match(prompt, /needs #7/);
    assert.match(prompt, /ready: \(nobody\)/);
  });
});
