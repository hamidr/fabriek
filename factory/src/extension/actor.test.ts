// The actor an extension makes of pi (ADR-033, ADR-035): announces ready,
// takes an assignment pointer, reads the issue, works it in a fresh session,
// reports an outcome under its own token, rewrites its memory, and announces
// ready again. Driven against a fake bus, a fake board and a fake agent, so
// what is asserted is the loop and not pi.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Actor, type Agent, type Board, type Bus } from "./actor.js";
import type { Message } from "../messages.js";

function fakes() {
  const sent: Message[] = [];
  const bus: Bus & { inbox: Message[] } = {
    inbox: [],
    async announce(m) { sent.push(m); },
    async ack(issue) { sent.push({ kind: "ack", issue }); },
    async held(issues) { sent.push({ kind: "held", issues }); },
    async event(name, payload) { sent.push({ kind: "event", name, payload }); },
    async finding(text) { sent.push({ kind: "finding", text }); },
  };
  const comments: { issue: number; body: string }[] = [];
  let memoryBody = "conventions: tabs";
  let blocked: number | null = null;
  const board: Board = {
    async issue(n) { return { number: n, title: `Task ${n}`, body: "do the thing", labels: ["build"], assignee: "builder" }; },
    async thread(n) { return n === 7 ? [{ by: "executor", body: "brief: acceptance is x" }] : []; },
    async comment(issue, body) { comments.push({ issue, body }); },
    async memory() { return { number: 3, body: memoryBody }; },
    async rewriteMemory(_n, body) { memoryBody = body; },
    async blockedOn() { return blocked; },
  };
  const calls: string[] = [];
  const agent: Agent = {
    prompt(text) { calls.push(`prompt:${text.split("\n")[0]}`); (agent as { lastPrompt?: string }).lastPrompt = text; },
    steer(text) { calls.push(`steer:${text}`); },
    abort() { calls.push("abort"); },
    finish() { calls.push("finish"); },
  };
  let commit = true;
  const checks = { async hasCommit() { return commit; } };
  return { bus, board, agent, sent, comments, calls, checks, setCommit: (v: boolean) => (commit = v), setBlocked: (v: number | null) => (blocked = v), memory: () => memoryBody };
}

const capabilities = ["build", "test"];

describe("an actor", () => {
  it("given a session start, it reads its memory and announces ready with its capabilities", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    assert.deepEqual(f.sent, [{ kind: "ready", capabilities }]);
    assert.equal(actor.state.kind, "idle");
  });

  it("when an assignment arrives while idle, it acks and prompts with the issue, the thread and its memory", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    assert.deepEqual(f.sent.at(-1), { kind: "ack", issue: 7 });
    assert.deepEqual(f.calls.slice(0, 1), ["prompt:You are the role builder."]);
    const prompt = (f.agent as { lastPrompt?: string }).lastPrompt ?? "";
    for (const piece of ["Task 7", "do the thing", "brief: acceptance is x", "conventions: tabs", "report_outcome"]) {
      assert.ok(prompt.includes(piece), `prompt carries ${piece}`);
    }
    assert.deepEqual(actor.state, { kind: "working", issue: 7, attempt: 1 });
  });

  it("given specialists, the brief names them after the role, so the brief and the system prompt agree", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, specialists: ["java", "python"], ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    const prompt = (f.agent as { lastPrompt?: string }).lastPrompt ?? "";
    assert.ok(prompt.startsWith("You are the role builder.\nYour specialists: java, python.\n"), prompt.split("\n").slice(0, 2).join(" | "));
  });

  it("given no specialists, the brief says nothing about them", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    const prompt = (f.agent as { lastPrompt?: string }).lastPrompt ?? "";
    assert.ok(!prompt.includes("specialists"), prompt.split("\n")[1]);
  });

  it("when an assignment arrives while working, it is refused and the actor keeps its task", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.handle({ kind: "assignment", issue: 8, attempt: 1 });
    assert.equal(f.sent.filter((m) => m.kind === "ack").length, 1);
    assert.deepEqual(actor.state, { kind: "working", issue: 7, attempt: 1 });
  });

  it("when the agent reports done with a commit, the outcome is commented, memory rewritten, and the process ended for a fresh one", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.reportOutcome({ status: "done", summary: "tests pass" });
    await actor.updateMemory("conventions: tabs; the importer lives in src/import");
    await actor.settled();
    assert.deepEqual(f.comments, [{ issue: 7, body: "outcome: done\n\ntests pass" }]);
    assert.equal(f.memory(), "conventions: tabs; the importer lives in src/import");
    assert.equal(f.calls.at(-1), "finish");
    assert.equal(f.sent.filter((m) => m.kind === "ready").length, 1);
    assert.equal(actor.state.kind, "idle");
  });

  it("given the board says this role is blocked, a fresh start holds that issue and announces nothing", async () => {
    const f = fakes();
    f.setBlocked(9);
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    assert.equal(f.sent.filter((m) => m.kind === "ready").length, 0);
    assert.deepEqual(actor.state, { kind: "blocked", issue: 9, attempt: 0 });
    await actor.handle({ kind: "reconcile" });
    assert.deepEqual(f.sent.at(-1), { kind: "held", issues: [9] });
  });

  it("when the agent reports done without a commit on its branch, the outcome says so as advice, and is still reported", async () => {
    const f = fakes();
    f.setCommit(false);
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.reportOutcome({ status: "done", summary: "tests pass" });
    await actor.settled();
    assert.match(f.comments[0]?.body ?? "", /^outcome: done\n/);
    assert.match(f.comments[0]?.body ?? "", /no commit/);
  });

  it("when the agent settles having reported nothing, the outcome is failed and says why, and the process ends", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.settled();
    assert.deepEqual(f.comments, [{ issue: 7, body: "outcome: failed\n\nthe session ended having reported no outcome" }]);
    assert.equal(f.calls.at(-1), "finish");
    assert.equal(actor.state.kind, "idle");
  });

  it("when the agent reports blocked, the actor keeps its task and never announces ready", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.reportOutcome({ status: "blocked", summary: "needs the schema from design" });
    await actor.settled();
    assert.deepEqual(f.comments, [{ issue: 7, body: "outcome: blocked\n\nneeds the schema from design" }]);
    assert.deepEqual(actor.state, { kind: "blocked", issue: 7, attempt: 1 });
    assert.equal(f.sent.filter((m) => m.kind === "ready").length, 1);
    assert.equal(f.calls.includes("finish"), false);
  });

  it("a steer reaches the running turn and an abort ends it", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.handle({ kind: "steer", text: "focus on the tests" });
    await actor.handle({ kind: "abort" });
    assert.deepEqual(f.calls.slice(-2), ["steer:focus on the tests", "abort"]);
  });

  it("a steer while idle is a question from the operator: answered in a turn of its own, the actor still idle after", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "steer", text: "status?" });
    assert.deepEqual(f.calls, ["prompt:The operator asks: status?"]);
    const prompt = (f.agent as { lastPrompt?: string }).lastPrompt ?? "";
    assert.ok(prompt.includes("Answer in words; you hold no task, so change nothing and report no outcome."), prompt);
    await actor.settled();
    assert.deepEqual(actor.state, { kind: "idle" });
    assert.equal(f.calls.includes("finish"), false);
    assert.deepEqual(f.comments, []);
  });

  it("a steer while blocked is answered the same way, and the actor keeps holding its task", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.reportOutcome({ status: "blocked", summary: "needs the schema" });
    await actor.settled();
    await actor.handle({ kind: "steer", text: "what do you need?" });
    assert.equal(f.calls.at(-1), "prompt:The operator asks: what do you need?");
    assert.deepEqual(actor.state, { kind: "blocked", issue: 7, attempt: 1 });
  });

  it("at reconciliation it answers with what it holds, working or blocked, and nothing when idle", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.handle({ kind: "reconcile" });
    assert.deepEqual(f.sent.at(-1), { kind: "held", issues: [] });
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.handle({ kind: "reconcile" });
    assert.deepEqual(f.sent.at(-1), { kind: "held", issues: [7] });
  });

  it("turn and tool events are published to the bus, as events and never as files", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.publish("tool_call", { tool: "bash" });
    assert.deepEqual(f.sent.at(-1), { kind: "event", name: "tool_call", payload: { tool: "bash" } });
  });

  it("a finding goes to the role's own findings stream", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.share("the importer chokes on BOMs");
    assert.deepEqual(f.sent.at(-1), { kind: "finding", text: "the importer chokes on BOMs" });
  });

  it("after the bus comes back, the actor announces ready again if it is idle, and held if it is not", async () => {
    const f = fakes();
    const actor = new Actor({ role: "builder", capabilities, ...f });
    await actor.start();
    await actor.reconnected();
    assert.deepEqual(f.sent.at(-1), { kind: "ready", capabilities });
    await actor.handle({ kind: "assignment", issue: 7, attempt: 1 });
    await actor.reconnected();
    assert.deepEqual(f.sent.at(-1), { kind: "held", issues: [7] });
  });
});
