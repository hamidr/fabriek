// The one face (ADR-039 point 3): the roles with one selected, the board
// by stage, what the factory did last, and the selected role's own stream,
// in panes sized to the terminal. Rendering is a pure function of the model
// and the screen, so it is asserted as text; colour is off here and the
// box glyphs are asserted by width, not by look.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { render } from "./view.js";
import { fold, initial, type State } from "./model.js";

function working(): State {
  let s = initial(["builder", "reviewer"]);
  s = fold(s, { stream: "control:builder", id: "1-0", fields: { kind: "ready", capabilities: "build" } });
  s = fold(s, { stream: "control:builder", id: "2-0", fields: { kind: "ack", issue: "7" } });
  s = fold(s, { stream: "events:executor", id: "3-0", fields: { kind: "event", name: "board", json: JSON.stringify({ issues: [{ number: 7, title: "Add importer", stage: "build", assignee: "builder", blocked: false }], ready: [], routing: true }) } });
  s = fold(s, { stream: "events:builder", id: "4-0", fields: { kind: "event", name: "tool_call", json: '{"toolName":"bash","input":{"command":"pwd && ls"}}' } });
  return s;
}

const wide = { columns: 120, rows: 30, factory: "acme", selected: "builder" };

describe("the TUI's view", () => {
  it("shows every role with its state, the selected one marked, the board by stage, the selected role's stream, and the keys", () => {
    const out = render(working(), wide);
    assert.match(out, /acme/);
    assert.match(out, /> builder +working #7/);
    assert.match(out, /  reviewer +unknown/);
    assert.match(out, /build\b[\s\S]*#7 Add importer \(builder\)/);
    assert.match(out, /builder .*\n[\s\S]*bash {2}pwd && ls/);
    for (const key of ["j/k role", "s steer", "x stop", "f file", "r retry", "b block", "p push", "m mirror", "q quit"]) {
      assert.ok(out.includes(key), `keys show ${key}`);
    }
  });

  it("the stream pane is the selected role's, and follows the selection", () => {
    let s = working();
    s = fold(s, { stream: "events:reviewer", id: "5-0", fields: { kind: "event", name: "tool_call", json: '{"toolName":"read","input":{"path":"README.md"}}' } });
    assert.match(render(s, wide), /pwd && ls/);
    assert.doesNotMatch(render(s, wide), /README\.md/);
    const other = render(s, { ...wide, selected: "reviewer" });
    assert.match(other, /README\.md/);
    assert.doesNotMatch(other, /pwd && ls/);
  });

  it("the stream shows its newest lines when there are more than fit", () => {
    let s = initial(["builder"]);
    for (let i = 0; i < 100; i++) s = fold(s, { stream: "events:builder", id: `${i}-0`, fields: { kind: "event", name: "turn_start", json: `{"turnIndex":${i}}` } });
    const out = render(s, { ...wide, rows: 20 });
    assert.match(out, /turn 100/);
    assert.doesNotMatch(out, /turn 1\D/);
  });

  it("shows a role's guard refusals for the task beside it, and flags a repeat", () => {
    const s = fold(
      fold(initial(["builder"]), { stream: "control:builder", id: "1-0", fields: { kind: "ready", capabilities: "build" } }),
      { stream: "events:builder", id: "2-0", fields: { kind: "event", name: "guard_refused", json: '{"rule":"run-before-code","tool":"edit","path":"src/a.py"}' } },
    );
    let text = render(s, wide);
    assert.match(text, /builder .*guard 1/);
    assert.doesNotMatch(text, /repeat/);
    const stuck = [1, 2].reduce(
      (st, i) => fold(st, { stream: "events:builder", id: `${i + 2}-0`, fields: { kind: "event", name: "guard_refused", json: '{"rule":"run-before-code","tool":"edit","path":"src/a.py"}' } }),
      s,
    );
    text = render(stuck, wide);
    assert.match(text, /guard 3 repeat/);
  });

  it("says when routing is stopped at the soft limit, and shows spend in total, for the decider and beside each role, in short figures", () => {
    let s = initial(["builder", "reviewer"]);
    s = fold(s, { stream: "events:executor", id: "3-0", fields: { kind: "event", name: "board", json: JSON.stringify({ issues: [], ready: [], routing: false }) } });
    s = fold(s, { stream: "events:executor", id: "4-0", fields: { kind: "event", name: "spend", json: '{"builder":7000,"reviewer":0,"decider":2000,"total":1400000}' } });
    const out = render(s, wide);
    assert.match(out, /routing stopped/);
    assert.match(out, /spend 1\.4M/);
    assert.match(out, /decider 2\.0k/);
    assert.match(out, /builder +unknown +7\.0k/);
    assert.match(out, /reviewer +unknown +0\b/);
  });

  it("what the factory did last is one list, newest last: commands and findings in the order they came", () => {
    let s = initial(["builder"]);
    s = fold(s, { stream: "commands", id: "1-0", fields: { json: '{"verb":"assign","issue":7,"role":"builder"}' } });
    s = fold(s, { stream: "findings:builder", id: "2-0", fields: { kind: "finding", text: "importer done" } });
    s = fold(s, { stream: "events:executor", id: "3-0", fields: { kind: "event", name: "command", json: '{"from":"commands","command":{"verb":"merge","issue":7},"result":{"ok":false,"reason":"not reviewed"}}' } });
    const out = render(s, wide);
    assert.match(out, /decider +assign 7 builder[\s\S]*builder +importer done[\s\S]*executor +refused merge 7: not reviewed/);
  });

  it("keeps the keys on the last row whatever the height, and a notice beside them", () => {
    const s = working();
    const out = render(s, { ...wide, rows: 12, notice: "acme: filed at design" });
    const lines = out.split("\n");
    assert.equal(lines.length, 12);
    assert.match(lines.at(-1) ?? "", /q quit/);
    assert.match(lines.at(-1) ?? "", /acme: filed at design/);
  });

  it("stacks the panes when the terminal is narrow, and never renders wider than it", () => {
    let s = working();
    s = fold(s, { stream: "findings:builder", id: "9-0", fields: { kind: "finding", text: "x".repeat(300) } });
    for (const columns of [60, 79, 120]) {
      const out = render(s, { ...wide, columns, rows: 40 });
      for (const line of out.split("\n")) assert.ok([...line].length <= columns, `line fits ${columns}: ${[...line].length}`);
      assert.match(out, /pwd && ls/);
    }
  });
});
