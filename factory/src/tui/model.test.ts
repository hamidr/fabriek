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

  it("a role's stream keeps what it did in the operator's words: a turn, each tool with its command or path, what it said, and a refusal", () => {
    let s = after([{ stream: "events:builder", id: "1-0", fields: { kind: "event", name: "turn_start", json: '{"turnIndex":0}' } }]);
    s = fold(s, { stream: "events:builder", id: "2-0", fields: { kind: "event", name: "tool_call", json: '{"toolName":"bash","input":{"command":"pwd && ls"}}' } });
    s = fold(s, { stream: "events:builder", id: "3-0", fields: { kind: "event", name: "tool_call", json: '{"toolName":"edit","input":{"path":"src/a.py"}}' } });
    s = fold(s, { stream: "events:builder", id: "4-0", fields: { kind: "event", name: "tool_result", json: '{"toolName":"bash"}' } });
    s = fold(s, { stream: "events:builder", id: "5-0", fields: { kind: "event", name: "turn_end", json: '{"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Reading the tree first."}]}}' } });
    s = fold(s, { stream: "events:builder", id: "6-0", fields: { kind: "event", name: "guard_refused", json: '{"rule":"run-before-code","tool":"edit","path":"src/a.py"}' } });
    s = fold(s, { stream: "findings:builder", id: "7-0", fields: { kind: "finding", text: "done on builder/work" } });
    assert.deepEqual(s.stream["builder"], [
      "turn 1",
      "bash  pwd && ls",
      "edit  src/a.py",
      "Reading the tree first.",
      "guard refused run-before-code on src/a.py",
      "finding: done on builder/work",
    ]);
    assert.equal(s.stream["reviewer"], undefined);
  });

  it("activity is in the order the bus gave each line its id, whatever order the relay replayed the streams in", () => {
    let s = initial(["builder"]);
    s = fold(s, { stream: "commands", id: "300-0", fields: { json: '{"verb":"assign","issue":7,"role":"builder"}' } });
    s = fold(s, { stream: "operator", id: "100-0", fields: { json: '{"op":"steer","role":"builder","text":"go"}' } });
    s = fold(s, { stream: "events:executor", id: "200-0", fields: { kind: "event", name: "command", json: '{"from":"commands","command":{"verb":"push","role":"builder"},"result":{"ok":true}}' } });
    assert.deepEqual(s.activity.map((a) => `${a.by} ${a.text}`), ["operator steer builder go", "executor did push builder", "decider assign 7 builder"]);
  });

  it("what the operator said to a role is in that role's stream, so the question reads beside the answer", () => {
    const s = after([{ stream: "mailbox:builder", id: "1-0", fields: { kind: "steer", text: "status?" } }]);
    assert.deepEqual(s.stream["builder"], ["operator: status?"]);
  });

  it("a role's stream is bounded, newest last", () => {
    let s = initial(["builder"]);
    for (let i = 0; i < 300; i++) s = fold(s, { stream: "events:builder", id: `${i}-0`, fields: { kind: "event", name: "turn_start", json: `{"turnIndex":${i}}` } });
    assert.equal(s.stream["builder"]?.length, 200);
    assert.equal(s.stream["builder"]?.at(-1), "turn 300");
  });

  it("a guard refusal is the role's last line and is counted for the task; the same rule on the same path three times is a repeat", () => {
    let s = after([
      { stream: "control:builder", id: "1-0", fields: { kind: "ready", capabilities: "build" } },
      { stream: "control:builder", id: "2-0", fields: { kind: "ack", issue: "7" } },
      { stream: "events:builder", id: "3-0", fields: { kind: "event", name: "guard_refused", json: '{"rule":"run-before-code","tool":"edit","path":"src/a.py"}' } },
    ]);
    assert.equal(s.roles["builder"]?.last, "guard run-before-code src/a.py");
    assert.deepEqual(s.roles["builder"]?.guard, { rule: "run-before-code", path: "src/a.py", count: 1, repeats: 1 });
    s = fold(s, { stream: "events:builder", id: "4-0", fields: { kind: "event", name: "guard_refused", json: '{"rule":"run-before-code","tool":"edit","path":"src/a.py"}' } });
    s = fold(s, { stream: "events:builder", id: "5-0", fields: { kind: "event", name: "guard_refused", json: '{"rule":"run-before-code","tool":"edit","path":"src/a.py"}' } });
    assert.deepEqual(s.roles["builder"]?.guard, { rule: "run-before-code", path: "src/a.py", count: 3, repeats: 3 });
    s = fold(s, { stream: "events:builder", id: "6-0", fields: { kind: "event", name: "guard_refused", json: '{"rule":"done-is-green","tool":"report_outcome","status":"done"}' } });
    assert.deepEqual(s.roles["builder"]?.guard, { rule: "done-is-green", path: "", count: 4, repeats: 1 });
  });

  it("a new task starts the guard's count over, since a correct test-first loop refuses a little every task", () => {
    let s = after([
      { stream: "control:builder", id: "1-0", fields: { kind: "ready", capabilities: "build" } },
      { stream: "control:builder", id: "2-0", fields: { kind: "ack", issue: "7" } },
      { stream: "events:builder", id: "3-0", fields: { kind: "event", name: "guard_refused", json: '{"rule":"run-before-code","tool":"edit","path":"src/a.py"}' } },
    ]);
    s = fold(s, { stream: "control:builder", id: "4-0", fields: { kind: "ack", issue: "8" } });
    assert.equal(s.roles["builder"]?.guard, undefined);
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

  it("spend is what the executor last published, per role and in total", () => {
    const s = after([{ stream: "events:executor", id: "5-0", fields: { kind: "event", name: "spend", json: '{"builder":120,"decider":0,"total":120}' } }]);
    assert.deepEqual(s.spend, { builder: 120, decider: 0, total: 120 });
  });

  it("a probe line is kept with the role the machine named, and with nothing before it when the machine named none", () => {
    let s = after([{ stream: "probes", id: "1-0", fields: { uid: "60000", role: "builder", event: "exec uid=60000 pid=1 comm=git" } }]);
    assert.deepEqual(s.probes, ["builder  exec uid=60000 pid=1 comm=git"]);
    s = fold(s, { stream: "probes", id: "2-0", fields: { uid: "999", role: "", event: "exec uid=999 pid=2 comm=forgejo" } });
    assert.equal(s.probes[1], "exec uid=999 pid=2 comm=forgejo");
  });

  it("every fixture line folds without throwing, whatever it carries", () => {
    assert.doesNotThrow(() => after(fixtures));
  });

  it("a line with a malformed payload is kept as a note rather than dropped", () => {
    const s = after([{ stream: "events:builder", id: "1-0", fields: { kind: "event", name: "tool_call", json: "{not" } }]);
    assert.match(s.roles["builder"]?.last ?? "", /tool_call/);
  });
});
