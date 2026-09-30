// What of a pi event reaches the bus: the fields pi declares for it, and not
// what its runtime carries beside them. pi 0.84 hands turn_end the whole
// session context, which grew one role's events past the bus's limit on a
// real run (2026-09-30), so each event is projected before it is published.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { eventPayload } from "./events.js";

const message = { role: "assistant", content: [{ type: "text", text: "done" }] };
const toolResult = { role: "toolResult", toolCallId: "c1", content: [{ type: "text", text: "ok" }] };

describe("a pi event as the bus carries it", () => {
  it("given a turn_end carrying the session's context, then its payload is the turn's index, message and tool results and nothing else", () => {
    const history = Array.from({ length: 50 }, () => message);
    const payload = eventPayload({ type: "turn_end", turnIndex: 4, message, toolResults: [toolResult], context: { llmMessages: history, contextMessages: history }, entries: history, continue: true });
    assert.deepEqual(payload, { turnIndex: 4, message, toolResults: [toolResult] });
  });

  it("given an agent_end, then its payload says how many messages the run had rather than carrying them", () => {
    assert.deepEqual(eventPayload({ type: "agent_end", messages: [message, message, message] }), { messages: 3 });
  });

  it("given a tool_call, then its payload is the tool's name, the call's id and its input", () => {
    const payload = eventPayload({ type: "tool_call", toolName: "bash", toolCallId: "c1", input: { command: "pytest -q" }, extra: "runtime" });
    assert.deepEqual(payload, { toolName: "bash", toolCallId: "c1", input: { command: "pytest -q" } });
  });

  it("given a tool_result, then its payload is the tool's name, the call's id, its content and whether it failed, without the input or details", () => {
    const payload = eventPayload({ type: "tool_result", toolName: "read", toolCallId: "c1", input: { path: "a" }, content: toolResult.content, details: { big: "x" }, isError: false });
    assert.deepEqual(payload, { toolName: "read", toolCallId: "c1", content: toolResult.content, isError: false });
  });

  it("given a turn_start or an agent_start, then only their declared fields travel", () => {
    assert.deepEqual(eventPayload({ type: "turn_start", turnIndex: 2, timestamp: 5, context: {} }), { turnIndex: 2, timestamp: 5 });
    assert.deepEqual(eventPayload({ type: "agent_start", context: {} }), {});
  });
});
