// What travels on the bus (ADR-033): a stream entry is flat string fields,
// so every message is parsed from fields and rendered back to them, and a
// message that says less than its kind requires is refused. The writer's
// identity is the ACL's and never the message's, so no message carries a
// role it could lie about beyond the one its stream is named for.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parseMessage, toFields, MessageError } from "./messages.js";

describe("messages on the bus", () => {
  it("given a ready announcement, it carries the capabilities the role provides", () => {
    const m = parseMessage({ kind: "ready", capabilities: "build,test" });
    assert.deepEqual(m, { kind: "ready", capabilities: ["build", "test"] });
  });

  it("given an assignment pointer, it names the issue and the attempt and nothing of the body", () => {
    const m = parseMessage({ kind: "assignment", issue: "7", attempt: "2" });
    assert.deepEqual(m, { kind: "assignment", issue: 7, attempt: 2 });
    assert.throws(() => parseMessage({ kind: "assignment", issue: "7", attempt: "2", body: "..." }), /body/);
  });

  it("given an ack, it names the issue the actor took", () => {
    assert.deepEqual(parseMessage({ kind: "ack", issue: "7" }), { kind: "ack", issue: 7 });
  });

  it("given a held answer at reconciliation, it lists issues and may list none", () => {
    assert.deepEqual(parseMessage({ kind: "held", issues: "7,9" }), { kind: "held", issues: [7, 9] });
    assert.deepEqual(parseMessage({ kind: "held", issues: "" }), { kind: "held", issues: [] });
  });

  it("given a steer or an abort from the operator, the text is text and the abort has none", () => {
    assert.deepEqual(parseMessage({ kind: "steer", text: "focus on the tests" }), { kind: "steer", text: "focus on the tests" });
    assert.deepEqual(parseMessage({ kind: "abort" }), { kind: "abort" });
  });

  it("given a turn or tool event, it carries a name and a JSON payload the relay passes through", () => {
    const m = parseMessage({ kind: "event", name: "tool_call", json: '{"tool":"bash"}' });
    assert.deepEqual(m, { kind: "event", name: "tool_call", payload: { tool: "bash" } });
    assert.throws(() => parseMessage({ kind: "event", name: "tool_call", json: "{not json" }), /json/);
  });

  it("given a finding, it is text alone; who found it is the stream's name", () => {
    assert.deepEqual(parseMessage({ kind: "finding", text: "the importer chokes on BOMs" }),
      { kind: "finding", text: "the importer chokes on BOMs" });
    assert.throws(() => parseMessage({ kind: "finding", text: "x", role: "builder" }), /role/);
  });

  it("when a kind is unknown, the message is refused by that word", () => {
    assert.throws(() => parseMessage({ kind: "outcome", text: "done" }), (e: unknown) =>
      e instanceof MessageError && /outcome/.test(e.message));
  });

  it("when a required field is missing or malformed, the message is refused naming the field", () => {
    assert.throws(() => parseMessage({ kind: "assignment", issue: "seven", attempt: "1" }), /issue/);
    assert.throws(() => parseMessage({ kind: "ready" }), /capabilities/);
    assert.throws(() => parseMessage({ kind: "ready", capabilities: "build,../x" }), /capabilit/);
  });

  it("every message renders to fields that parse back to itself", () => {
    const samples = [
      { kind: "ready", capabilities: "build" },
      { kind: "assignment", issue: "7", attempt: "1" },
      { kind: "ack", issue: "7" },
      { kind: "held", issues: "1,2" },
      { kind: "steer", text: "hi" },
      { kind: "abort" },
      { kind: "event", name: "turn_start", json: "{}" },
      { kind: "finding", text: "x" },
    ];
    for (const fields of samples) {
      const m = parseMessage(fields);
      assert.deepEqual(parseMessage(toFields(m)), m);
    }
  });
});
