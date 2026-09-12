// The one face (ADR-039 point 3): roles, the board by stage, the live line,
// findings and spend, on one screen sized to the terminal. Rendering is a
// pure function of the model, so it is asserted as text.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { render } from "./view.js";
import { fold, initial } from "./model.js";

describe("the TUI's view", () => {
  it("shows every role with its state and last line, the board by stage, and the keys", () => {
    let s = initial(["builder", "reviewer"]);
    s = fold(s, { stream: "control:builder", id: "1-0", fields: { kind: "ready", capabilities: "build" } });
    s = fold(s, { stream: "control:builder", id: "2-0", fields: { kind: "ack", issue: "7" } });
    s = fold(s, { stream: "events:executor", id: "3-0", fields: { kind: "event", name: "board", json: JSON.stringify({ issues: [{ number: 7, title: "Add importer", stage: "build", assignee: "builder", blocked: false }], ready: [], routing: true }) } });
    const out = render(s, { columns: 100, rows: 30, factory: "acme" });
    assert.match(out, /acme/);
    assert.match(out, /builder +working #7/);
    assert.match(out, /reviewer +unknown/);
    assert.match(out, /build\n +#7 Add importer \(builder\)/);
    for (const key of ["f file", "s steer", "x stop", "r retry", "b block", "p push", "m mirror", "q quit"]) {
      assert.ok(out.includes(key), `keys show ${key}`);
    }
  });

  it("says when routing is stopped at the soft limit, and shows spend", () => {
    let s = initial(["builder"]);
    s = fold(s, { stream: "events:executor", id: "3-0", fields: { kind: "event", name: "board", json: JSON.stringify({ issues: [], ready: [], routing: false }) } });
    s = fold(s, { stream: "events:executor", id: "4-0", fields: { kind: "event", name: "spend", json: '{"total":9000}' } });
    const out = render(s, { columns: 80, rows: 24, factory: "acme" });
    assert.match(out, /routing stopped/);
    assert.match(out, /spend +9000/);
  });

  it("never renders wider than the terminal", () => {
    let s = initial(["builder"]);
    s = fold(s, { stream: "findings:builder", id: "1-0", fields: { kind: "finding", text: "x".repeat(300) } });
    const out = render(s, { columns: 60, rows: 20, factory: "acme" });
    for (const line of out.split("\n")) assert.ok(line.length <= 60, `line fits: ${line.length}`);
  });
});
