// The binding between the actor and the world (ADR-035): a bus connection it
// announces on and reads its mailbox from, connecting again when the bus goes
// away, and the board it reads and writes. Against a scripted bus and a
// scripted forge, so that what is asserted is what reaches each.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import type { Entry } from "../bus/client.js";
import type { Issue, Comment } from "../forge/client.js";
import { bindActor, type ActorBus, type ActorForge } from "./bind.js";

function scriptedBus(reads: (Entry[] | Error)[]) {
  const written: { stream: string; fields: Record<string, string> }[] = [];
  const bus: ActorBus & { written: typeof written } = {
    written,
    closed: false,
    async xadd(stream, fields) {
      written.push({ stream, fields });
      return "1-0";
    },
    async xread() {
      const next = reads.shift();
      if (next === undefined) {
        await new Promise((r) => setTimeout(r, 5));
        return [];
      }
      if (next instanceof Error) {
        this.closed = true;
        throw next;
      }
      return next;
    },
    close() {
      this.closed = true;
    },
  };
  return bus;
}

function scriptedForge(issue: Issue, thread: Comment[] = []) {
  const comments: { n: number; body: string }[] = [];
  const forge: ActorForge & { comments: typeof comments } = {
    comments,
    issue: async () => issue,
    thread: async () => thread,
    comment: async (n, body) => {
      comments.push({ n, body });
    },
    memory: async () => ({ number: 1, body: "remembered" }),
    rewriteMemory: async () => {},
    blockedOn: async () => null,
  };
  return forge;
}

const tick = () => new Promise((r) => setTimeout(r, 20));

describe("binding an actor", () => {
  it("given a start, then ready is announced on the role's control stream with its capabilities", async () => {
    const bus = scriptedBus([]);
    const bound = bindActor({ role: "builder", capabilities: ["build"], connect: async () => bus, forge: scriptedForge({ number: 7, title: "t", body: "", labels: [], assignee: null }), agent: { prompt() {}, steer() {}, abort() {}, finish() {} }, checks: { hasCommit: async () => true }, retryMs: 1 });
    await bound.start();
    bound.stop();
    assert.deepEqual(bus.written[0], { stream: "control:builder", fields: { kind: "ready", capabilities: "build" } });
  });

  it("given an assignment on the mailbox, then it is acked, the agent is prompted with the issue, and a reported outcome is commented when the turn settles", async () => {
    const bus = scriptedBus([[{ id: "2-0", fields: { kind: "assignment", issue: "7", attempt: "1" } }]]);
    const forge = scriptedForge({ number: 7, title: "Add importer", body: "how", labels: ["build"], assignee: "builder" });
    const prompts: string[] = [];
    let finished = 0;
    const bound = bindActor({ role: "builder", capabilities: ["build"], connect: async () => bus, forge, agent: { prompt: (t) => prompts.push(t), steer() {}, abort() {}, finish: () => finished++ }, checks: { hasCommit: async () => true }, retryMs: 1 });
    await bound.start();
    try {
      await tick();
      assert.deepEqual(bus.written[1], { stream: "control:builder", fields: { kind: "ack", issue: "7" } });
      assert.match(prompts[0] ?? "", /Task #7, attempt 1: Add importer/);
      await bound.actor.reportOutcome({ status: "done", summary: "imported" });
      await bound.actor.settled();
      assert.deepEqual(forge.comments, [{ n: 7, body: "outcome: done\n\nimported" }]);
      assert.equal(finished, 1);
    } finally {
      bound.stop();
    }
  });

  it("given the bus goes away, then it connects again and announces ready once more", async () => {
    const first = scriptedBus([new Error("bus closed")]);
    const second = scriptedBus([]);
    const buses = [first, second];
    const bound = bindActor({ role: "builder", capabilities: ["build"], connect: async () => buses.shift() ?? second, forge: scriptedForge({ number: 1, title: "", body: "", labels: [], assignee: null }), agent: { prompt() {}, steer() {}, abort() {}, finish() {} }, checks: { hasCommit: async () => true }, retryMs: 1 });
    await bound.start();
    await tick();
    bound.stop();
    assert.deepEqual(first.written.map((w) => w.fields["kind"]), ["ready"]);
    assert.deepEqual(second.written.map((w) => w.fields["kind"]), ["ready"]);
  });

  it("given a mailbox entry that is not a message, then it is refused on the role's events and the loop goes on", async () => {
    const bus = scriptedBus([[{ id: "3-0", fields: { kind: "nonsense" } }]]);
    const bound = bindActor({ role: "builder", capabilities: ["build"], connect: async () => bus, forge: scriptedForge({ number: 1, title: "", body: "", labels: [], assignee: null }), agent: { prompt() {}, steer() {}, abort() {}, finish() {} }, checks: { hasCommit: async () => true }, retryMs: 1 });
    await bound.start();
    await tick();
    bound.stop();
    const refused = bus.written.find((w) => w.stream === "events:builder");
    assert.equal(refused?.fields["name"], "mailbox_refused");
  });
});
