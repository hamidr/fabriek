// The executor (ADR-034): uncaged, holds every credential, decides nothing.
// It writes the board, sends work, validates every verb against the
// declaration, and judges an outcome by what is checkable. Driven against
// fakes for the board, the bus, the sessions, git and the proxy's count, so
// what is asserted is the protocol (ADR-033 point 4) and the refusals
// (ADR-034 point 3), including the cases the withdrawn routing model owed:
// a crash between the board write and the send, a stall, and a liar at
// reconciliation.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Executor, type Board, type BoardIssue, type Bus, type Git, type Sessions, type Spend, type Streams } from "./core.js";
import type { Entry } from "./trace.js";
import { readDeclaration } from "../declaration.js";
import type { Message } from "../messages.js";

const declaration = readDeclaration(
  JSON.stringify({
    name: "acme",
    roles: {
      builder: { command: ["pi"], provides: ["build", "test"] },
      reviewer: { command: ["pi"], provides: ["review"] },
      manager: { command: ["pi"], provides: ["inspect"] },
    },
    workflows: { ship: { stages: [{ needs: "build" }, { needs: "test" }, { needs: "review" }, { needs: "inspect", verdict: true }] } },
    resources: { taskAttempts: 2, tokens: 1000 },
  }),
);

function fakes() {
  const issues = new Map<number, BoardIssue>();
  let next = 1;
  const log: string[] = [];
  const board: Board = {
    async open() { return [...issues.values()].filter((i) => i.state === "open"); },
    async issue(n) { const i = issues.get(n); if (!i) throw new Error(`no issue ${n}`); return i; },
    async create(title, body, stage) {
      const n = next++;
      issues.set(n, { number: n, title, body, state: "open", labels: [stage], assignee: null, thread: [] });
      log.push(`create:${n}:${stage}`);
      return n;
    },
    async setLabels(n, labels) { issues.get(n)!.labels = [...labels]; log.push(`labels:${n}:${[...labels].sort().join(",")}`); },
    async assign(n, role) { issues.get(n)!.assignee = role; log.push(`assign:${n}:${role ?? "-"}`); },
    async comment(n, body) { issues.get(n)!.thread.push({ by: "executor", body }); log.push(`comment:${n}:${body.split("\n")[0]}`); },
    async close(n) { issues.get(n)!.state = "closed"; log.push(`close:${n}`); },
    async openPullRequest(branch, title) { log.push(`pr:${branch}:${title}`); return 1; },
  };
  const sent: { role: string; message: Message }[] = [];
  const bus: Bus & { inbox: Message[] } = {
    inbox: [],
    async send(role, message) { sent.push({ role, message }); log.push(`send:${role}:${message.kind}`); },
  };
  const started: string[] = [];
  const stopped: string[] = [];
  const sessions: Sessions = {
    async start(role) { started.push(role); },
    async stop(role) { stopped.push(role); },
    running: () => new Set(started),
  };
  let commits = 1;
  let tips = 0;
  const git: Git = {
    async tip() { return `tip${tips++}`; },
    async commitsSince() { return commits; },
    async push(branch) { log.push(`push:${branch}`); },
    async mirror() { log.push("mirror"); },
  };
  let total = 0;
  const spend: Spend = { async total() { return total; } };
  const held: Record<string, Entry[]> = {};
  const streams: Streams = { async range(stream: string) { return held[stream] ?? []; } };
  const roleComment = (n: number, by: string, body: string) => issues.get(n)!.thread.push({ by, body });
  return { board, bus, sessions, git, spend, streams, held, issues, log, sent, started, stopped, roleComment, setCommits: (v: number) => (commits = v), setTotal: (v: number) => (total = v) };
}

async function executor(f = fakes()) {
  const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
  return { x, f };
}

describe("the executor", () => {
  // models/decider-ready.qnt: a reader that sees the same ready set from
  // two executors cannot tell that the second has not been asked yet.
  it("given the epoch it was started with, then its board carries it beside the ready set", async () => {
    const f = fakes();
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10, epoch: "2026-09-30T19:45:10.000Z" });
    const board = await x.snapshot();
    assert.equal(board.epoch, "2026-09-30T19:45:10.000Z");
    assert.deepEqual(board.ready, []);
  });
  it("given a filed goal, it opens an issue at the workflow's first stage and nothing else", async () => {
    const { x, f } = await executor();
    const r = await x.apply({ verb: "file", titleFile: "/t", bodyFile: "/b", stage: "build" }, { readFile: async (p) => (p === "/t" ? "Add importer" : "handle empty files") });
    assert.equal(r.ok, true);
    assert.deepEqual(f.log, ["create:1:build"]);
    assert.equal(f.issues.get(1)?.title, "Add importer");
  });

  it("file at a stage the workflow lacks is refused by name", async () => {
    const { x } = await executor();
    const r = await x.apply({ verb: "file", titleFile: "/t", bodyFile: "/b", stage: "deploy" }, { readFile: async () => "x" });
    assert.equal(r.ok, false);
    assert.match(r.ok ? "" : r.reason, /deploy/);
  });

  it("assign writes assigning to the board before it sends, and assigned only on the ack", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.equal(r.ok, true);
    const i = f.log.indexOf("labels:1:assigning,build");
    const s = f.log.indexOf("send:builder:assignment");
    assert.ok(i >= 0 && s > i, `board before send: ${f.log.join(" ")}`);
    assert.deepEqual(f.sent[0]?.message, { kind: "assignment", issue: 1, attempt: 1 });
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigning", "build"]);
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "build"]);
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  // models/orphaned-assignment.qnt, and a host (2026-09-30): the executor
  // stopped, ending the session that held an acked task, and the role's
  // next session announced ready holding nothing. The row stayed assigned
  // and the decider waited on it for good.
  async function acked(x: Executor, f: ReturnType<typeof fakes>) {
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
  }

  it("given a row its role acked, when the role announces ready with no outcome since the attempt began, then the row is freed for a retry and the thread says why", async () => {
    const { x, f } = await executor();
    await acked(x, f);
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels, ["build"]);
    assert.equal(f.issues.get(1)?.assignee, "builder");
    assert.match(f.issues.get(1)?.thread.at(-1)?.body ?? "", /^attempt 1 abandoned: builder started again without it/);
    assert.deepEqual(await x.apply({ verb: "retry", issue: 1 }), { ok: true });
  });

  it("given a ready the role said before it acked, when both are read in one batch, then the row it acked stays assigned", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "build"]);
  });

  it("given a role that commented its outcome and then announced ready, then the ready frees nothing and the outcome is judged as ever", async () => {
    const { x, f } = await executor();
    await acked(x, f);
    f.roleComment(1, "builder", "outcome: done\n\nbuilt");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "build"]);
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
  });

  // Seen on a host (2026-10-01): a blocked outcome stays on an assigned
  // row, and every ten seconds the executor wrote its trace under it
  // again, nine times before anyone looked.
  it("given a blocked outcome, when outcomes are checked again and again, then it is judged once: one trace, the row blocked", async () => {
    const { x, f } = await executor();
    await acked(x, f);
    f.roleComment(1, "builder", "outcome: blocked\n\nno pytest in this shell");
    await x.checkOutcomes();
    await x.checkOutcomes();
    await x.checkOutcomes();
    assert.equal(f.issues.get(1)?.thread.filter((c) => c.body.startsWith("trace:")).length, 1);
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "blocked", "build"]);
  });

  it("given a row blocked on another, when its role announces ready, then the row stays as it is", async () => {
    const { x, f } = await executor();
    await acked(x, f);
    await f.board.setLabels(1, ["build", "assigned", "blocked"]);
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "blocked", "build"]);
  });

  it("assign is refused for a role that does not exist, does not provide the stage, is not ready, or holds work", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    let r = await x.apply({ verb: "assign", issue: 1, role: "ghost" });
    assert.match(r.ok ? "" : r.reason, /ghost/);
    r = await x.apply({ verb: "assign", issue: 1, role: "reviewer" });
    assert.match(r.ok ? "" : r.reason, /reviewer.*build/);
    r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.match(r.ok ? "" : r.reason, /not ready/);
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.equal(r.ok, true);
    r = await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.match(r.ok ? "" : r.reason, /holds/);
  });

  it("assign is refused past the declared attempts, and a retry names the same role", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    f.issues.get(1)!.assignee = "builder";
    f.roleComment(1, "executor", "attempt 1 started for builder at build (branch at none)");
    f.roleComment(1, "executor", "attempt 2 started for builder at build (branch at none)");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "retry", issue: 1 });
    assert.match(r.ok ? "" : r.reason, /attempts/);
  });

  it("retry goes back to the role that had the task, with the previous outcome in the brief", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    f.issues.get(1)!.assignee = "builder";
    f.roleComment(1, "executor", "attempt 1 started for builder at build (branch at none)");
    f.roleComment(1, "builder", "outcome: failed\n\nthe tests would not compile");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "retry", issue: 1 });
    assert.equal(r.ok, true);
    assert.deepEqual(f.sent[0]?.message, { kind: "assignment", issue: 1, attempt: 2 });
    const brief = f.issues.get(1)?.thread.at(-1)?.body ?? "";
    assert.match(brief, /attempt 2 started for builder/);
    assert.match(brief, /the tests would not compile/);
  });

  it("when the actor never acks, the row stays assigning and the role is not free for another task", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    await x.settle();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigning", "build"]);
    const r = await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.equal(r.ok, false);
  });

  it("on start it reconciles: an assigning row an actor says it holds becomes assigned; one nobody holds is released", async () => {
    const f = fakes();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    f.issues.get(1)!.labels = ["build", "assigning"]; f.issues.get(1)!.assignee = "builder";
    f.issues.get(2)!.labels = ["build", "assigning"]; f.issues.get(2)!.assignee = "reviewer";
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    const done = x.reconcile();
    x.heard("builder", { kind: "held", issues: [1] });
    x.heard("reviewer", { kind: "held", issues: [] });
    await done;
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "build"]);
    assert.deepEqual(f.issues.get(2)?.labels.sort(), ["build"]);
    assert.equal(f.issues.get(2)?.assignee, null);
    assert.ok(f.sent.every((s) => s.message.kind === "reconcile"));
  });

  it("at reconciliation a liar cannot take a task: an answer never creates an assignment", async () => {
    const f = fakes();
    await f.board.create("t", "b", "build");
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    const done = x.reconcile();
    x.heard("builder", { kind: "held", issues: [1] });
    await done;
    assert.deepEqual(f.issues.get(1)?.labels, ["build"]);
    assert.equal(f.issues.get(1)?.assignee, null);
  });

  it("an actor that does not answer reconciliation is unknown: its assigning row stays and nothing is routed to it", async () => {
    const f = fakes();
    await f.board.create("t", "b", "build");
    f.issues.get(1)!.labels = ["build", "assigning"]; f.issues.get(1)!.assignee = "builder";
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    await x.reconcile();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigning", "build"]);
    x.heard("builder", { kind: "ready", capabilities: ["build"] });
    await f.board.create("t2", "b", "build");
    const r = await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.equal(r.ok, false);
  });

  it("a done outcome with a signed commit on the role's branch moves the issue to the next stage and frees the role", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: done\n\nall green");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
    assert.equal(f.issues.get(1)?.assignee, null);
  });

  it("a done outcome without a commit is not done: the issue stays at its stage, unassigned, and the thread says why", async () => {
    const { x, f } = await executor();
    f.setCommits(0);
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: done\n\nall green");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["build"]);
    assert.match(f.issues.get(1)?.thread.at(-1)?.body ?? "", /no commit/);
  });

  it("the attempt comment records the branch's tip, and a done with no commit after it is not done even if earlier tasks left commits", async () => {
    const { x, f } = await executor();
    await f.board.create("first", "b", "build");
    await f.board.create("second", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.match(f.issues.get(1)?.thread[0]?.body ?? "", /^attempt 1 started for builder at build \(branch at tip0\)$/);
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: done\n\nfirst task");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
    // The branch now carries the first task's commit; the second adds none.
    f.setCommits(0);
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 2, role: "builder" });
    assert.match(f.issues.get(2)?.thread[0]?.body ?? "", /\(branch at tip1\)$/);
    x.heard("builder", { kind: "ack", issue: 2 });
    await x.settle();
    f.roleComment(2, "builder", "outcome: done\n\nnothing new");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(2)?.labels, ["build"]);
    assert.equal(f.issues.get(2)?.assignee, null);
  });

  it("attempts are counted per stage: a task that used its budget at build still has it at test, and the reviewer's first attempt is attempt 1", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    for (const attempt of [1, 2]) {
      x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
      assert.deepEqual(await x.apply({ verb: "assign", issue: 1, role: "builder" }), { ok: true });
      x.heard("builder", { kind: "ack", issue: 1 });
      await x.settle();
      f.roleComment(1, "builder", attempt === 1 ? "outcome: failed\n\nno" : "outcome: done\n\nyes");
      await x.checkOutcomes();
    }
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
    // The same role serves the next stage, and its budget there is untouched.
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    assert.deepEqual(await x.apply({ verb: "assign", issue: 1, role: "builder" }), { ok: true });
    assert.match(f.issues.get(1)?.thread.at(-1)?.body ?? "", /^attempt 1 started for builder at test/);
  });

  it("a done outcome at the last stage closes the issue", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "inspect");
    x.heard("manager", { kind: "ready", capabilities: ["inspect"] });
    await x.apply({ verb: "assign", issue: 1, role: "manager" });
    x.heard("manager", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "manager", "outcome: done\n\nnothing to change");
    await x.checkOutcomes();
    assert.equal(f.issues.get(1)?.state, "closed");
  });

  // ADR-051: what an attempt used is written into its thread before the
  // stage moves, cut from the streams that still hold it.
  it("an outcome is preceded in the thread by a trace of the attempt, cut from the role's events and the probes", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    const ev = (id: string, name: string, payload: unknown): Entry => ({ id, fields: { kind: "event", name, json: JSON.stringify(payload) } });
    f.held["events:builder"] = [
      ev("1-0", "task_started", { issue: 1, attempt: 1 }),
      ev("2-0", "tool_call", { toolName: "bash", input: { command: "npm test" } }),
      ev("3-0", "task_ended", { issue: 1, attempt: 1, status: "done" }),
    ];
    f.held["probes"] = [{ id: "2-1", fields: { cgroup: "1", role: "builder", event: "exec cgroup=1 uid=1 pid=1 comm=node" } }];
    f.roleComment(1, "builder", "outcome: done\n\nshipped");
    await x.checkOutcomes();
    const thread = f.issues.get(1)!.thread.map((c) => c.body);
    const trace = thread.find((b) => b.startsWith("trace:"));
    assert.equal(trace, "trace: attempt 1 of builder\nturns: 0\ntools: bash 1\ncommands: 1x npm test\nexecutables: node 1");
    assert.ok(thread.indexOf(trace!) > thread.findIndex((b) => b.startsWith("outcome:")));
    assert.deepEqual(f.issues.get(1)?.labels, ["test"]);
  });

  it("a stage declared verdict takes done with no commit, and one not declared still does not", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "inspect");
    x.heard("manager", { kind: "ready", capabilities: ["inspect"] });
    await x.apply({ verb: "assign", issue: 1, role: "manager" });
    x.heard("manager", { kind: "ack", issue: 1 });
    await x.settle();
    f.setCommits(0);
    f.roleComment(1, "manager", "outcome: done\n\nnothing to change");
    await x.checkOutcomes();
    assert.equal(f.issues.get(1)?.state, "closed");
    assert.ok(!f.issues.get(1)?.thread.some((c) => /no commit/.test(c.body)));
  });

  // ADR-055: concurrency is how many tasks may be in flight, held by the
  // executor; the machine sizes each cage by the same number.
  it("an assignment past the declared concurrency is refused naming the number, and one within it goes through", async () => {
    const f = fakes();
    const d = readDeclaration(JSON.stringify({ ...JSON.parse(JSON.stringify(declaration)), resources: { taskAttempts: 2, tokens: 1000, concurrency: 1 } }));
    const x = new Executor({ declaration: d, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    await f.board.create("a", "", "build");
    await f.board.create("b", "", "review");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    x.heard("reviewer", { kind: "ready", capabilities: ["review"] });
    assert.deepEqual(await x.apply({ verb: "assign", issue: 1, role: "builder" }), { ok: true });
    const r = await x.apply({ verb: "assign", issue: 2, role: "reviewer" });
    assert.match(r.ok ? "" : r.reason, /concurrency is 1.*1 role.* holds work/);
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: failed\n\nno");
    await x.checkOutcomes();
    assert.deepEqual(await x.apply({ verb: "assign", issue: 2, role: "reviewer" }), { ok: true });
  });

  it("with no concurrency declared, every ready role may hold work at once", async () => {
    const { x, f } = await executor();
    await f.board.create("a", "", "build");
    await f.board.create("b", "", "review");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    x.heard("reviewer", { kind: "ready", capabilities: ["review"] });
    assert.deepEqual(await x.apply({ verb: "assign", issue: 1, role: "builder" }), { ok: true });
    assert.deepEqual(await x.apply({ verb: "assign", issue: 2, role: "reviewer" }), { ok: true });
  });

  it("a blocked outcome labels the issue blocked and the role keeps it", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: blocked\n\nneeds the schema");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels.sort(), ["assigned", "blocked", "build"]);
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  it("a failed outcome frees the role and leaves the issue for the decider to retry", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    x.heard("builder", { kind: "ack", issue: 1 });
    await x.settle();
    f.roleComment(1, "builder", "outcome: failed\n\nno");
    await x.checkOutcomes();
    assert.deepEqual(f.issues.get(1)?.labels, ["build"]);
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  it("block labels the issue and says what it waits on, and refuses an issue that does not exist", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    await f.board.create("t2", "b", "build");
    let r = await x.apply({ verb: "block", issue: 1, on: 2 });
    assert.equal(r.ok, true);
    assert.ok(f.issues.get(1)?.labels.includes("blocked"));
    assert.match(f.issues.get(1)?.thread.at(-1)?.body ?? "", /#2/);
    r = await x.apply({ verb: "block", issue: 1, on: 9 });
    assert.equal(r.ok, false);
  });

  it("push pushes only the role's own namespace and opens one pull request for it", async () => {
    const { x, f } = await executor();
    const r = await x.apply({ verb: "push", role: "builder" });
    assert.equal(r.ok, true);
    assert.deepEqual(f.log, ["push:builder/work", "pr:builder/work:builder/work"]);
    const bad = await x.apply({ verb: "push", role: "ghost" });
    assert.equal(bad.ok, false);
  });

  it("stop sends an abort to the role and keeps its assignment", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    await x.apply({ verb: "assign", issue: 1, role: "builder" });
    const r = await x.apply({ verb: "stop", role: "builder" });
    assert.equal(r.ok, true);
    assert.deepEqual(f.sent.at(-1)?.message, { kind: "abort" });
    assert.equal(f.issues.get(1)?.assignee, "builder");
  });

  it("at the soft limit, assign is refused and running work is left to finish", async () => {
    const { x, f } = await executor();
    f.setTotal(950);
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.match(r.ok ? "" : r.reason, /soft limit/);
    assert.equal(x.routing(), false);
  });

  it("credential age: past its maxAge assign is refused naming the host, and routing resumes when the credential is fresh again", async () => {
    const f = fakes();
    let late: string | null = "gw.example.test";
    const x = new Executor({ declaration, workflow: "ship", ...f, reconcileTimeoutMs: 10, credentials: { overdue: async () => late } });
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const held = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.match(held.ok ? "" : held.reason, /gw\.example\.test.*maxAge/);
    assert.ok(!f.issues.get(1)?.assignee);
    late = null;
    const again = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.equal(again.ok, true);
  });

  it("credential age: with no limit declared the age is never asked", async () => {
    const { x, f } = await executor();
    await f.board.create("t", "b", "build");
    x.heard("builder", { kind: "ready", capabilities: ["build", "test"] });
    const r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.equal(r.ok, true);
  });

  it("at the ceiling the executor says so", async () => {
    const { x, f } = await executor();
    f.setTotal(1000);
    assert.equal(await x.atCeiling(), true);
  });

  it("between the soft limit and the ceiling, assign is refused and the ceiling is not reached", async () => {
    const { x, f } = await executor();
    f.setTotal(950);
    assert.equal(await x.atCeiling(), false);
    const r = await x.apply({ verb: "assign", issue: 1, role: "builder" });
    assert.equal(r.ok, false);
  });

  it("below the soft limit the ceiling is not reached", async () => {
    const { x, f } = await executor();
    f.setTotal(10);
    assert.equal(await x.atCeiling(), false);
  });

  it("with no ceiling declared, the ceiling is never reached", async () => {
    const f = fakes();
    const unbounded = readDeclaration(JSON.stringify({ ...JSON.parse(JSON.stringify(declaration)), resources: { taskAttempts: 2 } }));
    const x = new Executor({ declaration: unbounded, workflow: "ship", ...f, reconcileTimeoutMs: 10 });
    f.setTotal(1000000);
    assert.equal(await x.atCeiling(), false);
  });

  it("mirror brings main and the record into the clone together", async () => {
    const { x, f } = await executor();
    await x.mirror();
    assert.deepEqual(f.log, ["mirror"]);
  });
});
