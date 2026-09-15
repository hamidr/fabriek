// The trace of an attempt (ADR-051): what the events stream and the probes
// saw between the actor's task_started and task_ended brackets, summarised
// into one comment for the thread. Pure over stream entries, so what is
// asserted is the cut and the counting and never a bus.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { traceOf, type Entry } from "./trace.js";

const event = (id: string, name: string, payload: unknown): Entry => ({ id, fields: { kind: "event", name, json: JSON.stringify(payload) } });
const probe = (id: string, role: string, comm: string): Entry => ({ id, fields: { cgroup: "1", role, event: `exec cgroup=1 uid=700000 pid=1 comm=${comm}` } });
const call = (id: string, toolName: string, input: unknown): Entry => event(id, "tool_call", { toolName, toolCallId: id, input });

describe("the trace of an attempt", () => {
  it("counts turns, tools by name, commands, executables and skills between the attempt's brackets and nothing outside them", () => {
    const events: Entry[] = [
      call("1-0", "bash", { command: "ls" }),
      event("2-0", "task_started", { issue: 7, attempt: 2 }),
      event("3-0", "turn_start", {}),
      call("4-0", "read", { path: "/run/fabriek/pi/skills/tdd/SKILL.md" }),
      call("5-0", "codegraph_explore", { query: "importer" }),
      call("6-0", "bash", { command: "npm test" }),
      call("7-0", "bash", { command: "npm test\n# again" }),
      call("8-0", "edit", { path: "src/importer.ts" }),
      event("9-0", "turn_start", {}),
      call("10-0", "bash", { command: "git commit -m 'Handle empty files'" }),
      event("11-0", "task_ended", { issue: 7, attempt: 2, status: "done" }),
      call("12-0", "bash", { command: "rm -rf /" }),
    ];
    const probes: Entry[] = [probe("1-5", "builder", "ls"), probe("6-1", "builder", "node"), probe("7-1", "builder", "node"), probe("8-1", "reviewer", "cat"), probe("10-1", "builder", "git")];
    const text = traceOf({ role: "builder", issue: 7, attempt: 2, events, probes });
    assert.equal(
      text,
      [
        "trace: attempt 2 of builder",
        "turns: 2",
        "tools: bash 3, codegraph_explore 1, edit 1, read 1",
        "commands: 2x npm test; 1x git commit -m 'Handle empty files'",
        "executables: node 2, git 1",
        "skills: tdd",
      ].join("\n"),
    );
  });

  it("names guard refusals with their rule and what was refused", () => {
    const events: Entry[] = [
      event("1-0", "task_started", { issue: 7, attempt: 1 }),
      event("2-0", "guard_refused", { rule: "test-first", tool: "edit", path: "src/importer.ts" }),
      event("3-0", "guard_refused", { rule: "test-first", tool: "report_outcome", status: "done" }),
      event("4-0", "task_ended", { issue: 7, attempt: 1, status: "failed" }),
    ];
    const text = traceOf({ role: "builder", issue: 7, attempt: 1, events, probes: [] });
    assert.match(text, /^guard refused: 2 \(test-first: edit src\/importer.ts; test-first: report_outcome done\)$/m);
    assert.match(text, /^tools: none$/m);
  });

  it("cuts the latest attempt with those numbers when the stream holds an earlier one of the same task", () => {
    const events: Entry[] = [
      event("1-0", "task_started", { issue: 7, attempt: 1 }),
      call("2-0", "bash", { command: "old" }),
      event("3-0", "task_ended", { issue: 7, attempt: 1, status: "failed" }),
      event("4-0", "task_started", { issue: 7, attempt: 2 }),
      call("5-0", "bash", { command: "new" }),
      event("6-0", "task_ended", { issue: 7, attempt: 2, status: "done" }),
    ];
    const text = traceOf({ role: "builder", issue: 7, attempt: 2, events, probes: [] });
    assert.match(text, /^commands: 1x new$/m);
    assert.doesNotMatch(text, /old/);
  });

  it("says so when the stream no longer holds the attempt, rather than tracing whatever is there", () => {
    const events: Entry[] = [call("5-0", "bash", { command: "npm test" }), event("6-0", "task_ended", { issue: 7, attempt: 2, status: "done" })];
    const text = traceOf({ role: "builder", issue: 7, attempt: 2, events, probes: [] });
    assert.equal(text, "trace: not observed; the events stream no longer holds attempt 2 of builder");
  });

  it("shortens a long command to its first line and a hundred characters, and skips an entry whose payload is not json", () => {
    const long = "x".repeat(150);
    const events: Entry[] = [
      event("1-0", "task_started", { issue: 1, attempt: 1 }),
      call("2-0", "bash", { command: `${long}\nsecond line` }),
      { id: "3-0", fields: { kind: "event", name: "tool_call", json: "{not json" } },
      event("4-0", "task_ended", { issue: 1, attempt: 1, status: "done" }),
    ];
    const text = traceOf({ role: "builder", issue: 1, attempt: 1, events, probes: [] });
    assert.match(text, new RegExp(`^commands: 1x ${"x".repeat(100)}\\.\\.\\.$`, "m"));
    assert.match(text, /^tools: bash 1$/m);
  });
});
