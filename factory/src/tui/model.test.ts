// What the TUI knows is what the relay said (ADR-039 point 3): every line is
// folded into one state, roles and their turns, the board as the executor
// last published it, findings, the decider's commands and the spend. Pure,
// so a line can be replayed and the same state comes out.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fold, initial, type Line } from "./model.js";

const fixtures = JSON.parse(readFileSync(new URL("../relay/fixtures.json", import.meta.url), "utf8")) as Line[];

function after(lines: Line[]) {
  return lines.reduce(fold, initial(["builder", "reviewer"]));
}

describe("the TUI's model", () => {
  it("starts with every declared role idle and unknown, and no board", () => {
    const s = initial(["builder", "reviewer"]);
    assert.deepEqual(Object.keys(s.roles), ["builder", "reviewer"]);
    assert.equal(s.roles["builder"]?.state, "unknown");
    assert.deepEqual(s.board, []);
  });

  it("a ready makes a role idle, an ack makes it working on that issue, and a blocked outcome event marks it blocked", () => {
    let s = after([{ stream: "control:builder", id: "1-0", fields: { kind: "ready", capabilities: "build" } }]);
    assert.equal(s.roles["builder"]?.state, "idle");
    s = fold(s, { stream: "control:builder", id: "2-0", fields: { kind: "ack", issue: "7" } });
    assert.deepEqual(s.roles["builder"], { state: "working", issue: 7, last: "ack #7" });
  });

  it("turn and tool events become the role's last line, with the tool named", () => {
    const s = after([
      { stream: "control:builder", id: "1-0", fields: { kind: "ready", capabilities: "build" } },
      { stream: "events:builder", id: "3-0", fields: { kind: "event", name: "tool_call", json: '{"toolName":"bash"}' } },
    ]);
    assert.equal(s.roles["builder"]?.last, "tool_call bash");
  });

  it("the board is what the executor last published, grouped by stage", () => {
    const s = after([
      { stream: "events:executor", id: "9-0", fields: { kind: "event", name: "board", json: JSON.stringify({ issues: [{ number: 7, title: "Add importer", stage: "build", assignee: "builder", blocked: false }, { number: 8, title: "Review", stage: "review", assignee: null, blocked: false }], ready: ["reviewer"], routing: true }) } },
    ]);
    assert.deepEqual(s.board.map((i) => `${i.stage}:${i.number}`), ["build:7", "review:8"]);
    assert.equal(s.routing, true);
  });

  it("findings and commands are kept newest last, and bounded", () => {
    let s = initial(["builder"]);
    for (let i = 0; i < 60; i++) s = fold(s, { stream: "findings:builder", id: `${i}-0`, fields: { kind: "finding", text: `f${i}` } });
    assert.equal(s.findings.length, 50);
    assert.equal(s.findings.at(-1)?.text, "f59");
    s = fold(s, { stream: "commands", id: "70-0", fields: { json: '{"verb":"assign","issue":7,"role":"builder"}' } });
    assert.deepEqual(s.commands.at(-1), { by: "decider", text: "assign 7 builder" });
    s = fold(s, { stream: "events:executor", id: "71-0", fields: { kind: "event", name: "command", json: '{"from":"commands","command":{"verb":"assign","issue":7,"role":"builder"},"result":{"ok":false,"reason":"role builder is not ready"}}' } });
    assert.deepEqual(s.commands.at(-1), { by: "executor", text: "refused assign 7 builder: role builder is not ready" });
  });

  it("spend is what the executor last published, per address and in total", () => {
    const s = after([{ stream: "events:executor", id: "5-0", fields: { kind: "event", name: "spend", json: '{"10.77.0.10":120,"total":120}' } }]);
    assert.deepEqual(s.spend, { "10.77.0.10": 120, total: 120 });
  });

  it("every fixture line folds without throwing, whatever it carries", () => {
    assert.doesNotThrow(() => after(fixtures));
  });

  it("a line with a malformed payload is kept as a note rather than dropped", () => {
    const s = after([{ stream: "events:builder", id: "1-0", fields: { kind: "event", name: "tool_call", json: "{not" } }]);
    assert.match(s.roles["builder"]?.last ?? "", /tool_call/);
  });
});
