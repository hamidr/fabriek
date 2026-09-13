// The decider bound to the world (ADR-034 point 1): the board read with its
// token, the ready set kept off every control stream, the commands stream
// written through the gate, and a think whenever something changed. Against
// a scripted bus and forge, so what is asserted is what reaches each.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import type { Entry } from "../bus/client.js";
import { readDeclaration } from "../declaration.js";
import { bindDecider, type DeciderBus, type DeciderForge } from "./bind.js";
import type { Snapshot } from "./core.js";

const declaration = readDeclaration(
  JSON.stringify({
    name: "acme",
    roles: { builder: { command: ["pi"], provides: ["build"] }, reviewer: { command: ["pi"], provides: ["review"] } },
    workflows: { ship: { stages: [{ needs: "build" }, { needs: "review" }] } },
    resources: { taskAttempts: 3 },
  }),
);

function scriptedBus(reads: Record<string, Entry[]>[]) {
  const written: { stream: string; fields: Record<string, string> }[] = [];
  const bus: DeciderBus & { written: typeof written } = {
    written,
    closed: false,
    async xadd(stream, fields) {
      written.push({ stream, fields });
      return "1-0";
    },
    async xreadMany() {
      const next = reads.shift();
      if (next === undefined) {
        await new Promise((r) => setTimeout(r, 5));
        return {};
      }
      return next;
    },
    close() {
      this.closed = true;
    },
  };
  return bus;
}

const forge: DeciderForge = {
  call: async <T,>(_method: string, path: string): Promise<T> => {
    if (path.includes("/issues?")) {
      return [
        { number: 7, title: "Add importer", labels: [{ name: "build" }], assignees: [] },
        { number: 3, title: "memory: builder", labels: [{ name: "memory" }], assignees: [] },
      ] as T;
    }
    throw new Error(`unscripted ${path}`);
  },
  thread: async () => [{ by: "executor", body: "attempt 1 started for builder at build (branch at none)" }, { by: "builder", body: "outcome: failed\n\nno" }],
};

const tick = () => new Promise((r) => setTimeout(r, 20));

describe("binding a decider", () => {
  it("given a start, then it thinks once on the board as the forge shows it, memory issues left out and attempts counted", async () => {
    const thought: Snapshot[] = [];
    const bound = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([]), forge, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1 });
    await bound.start();
    bound.stop();
    assert.equal(thought.length, 1);
    assert.deepEqual(thought[0]?.issues, [{ number: 7, title: "Add importer", stage: "build", assignee: null, attempts: 1, blocked: false, lastOutcome: null }]);
    assert.deepEqual(thought[0]?.ready, []);
  });

  it("given a ready on a role's control stream, then the ready set has it and it thinks again; an ack takes it out", async () => {
    const thought: Snapshot[] = [];
    const bus = scriptedBus([
      { "control:builder": [{ id: "1-0", fields: { kind: "ready", capabilities: "build" } }] },
      { "control:builder": [{ id: "2-0", fields: { kind: "ack", issue: "7" } }] },
    ]);
    const bound = bindDecider({ declaration, policy: null, connect: async () => bus, forge, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1 });
    await bound.start();
    try {
      await tick();
      const seen = thought.map((s) => s.ready);
      assert.ok(seen.some((r) => r.includes("builder")), `some thought saw builder ready: ${JSON.stringify(seen)}`);
      assert.deepEqual(seen.at(-1), []);
    } finally {
      bound.stop();
    }
  });

  it("given a command through the core, then it lands on the commands stream as JSON, and one the gate refuses does not", async () => {
    const bus = scriptedBus([]);
    const bound = bindDecider({ declaration, policy: null, connect: async () => bus, forge, think: async () => {}, tickMs: 60000, retryMs: 1 });
    await bound.start();
    try {
      assert.deepEqual(await bound.core.command({ verb: "assign", issue: 7, role: "builder" }), { ok: true });
      assert.equal((await bound.core.command({ verb: "assign", issue: 7, role: "nobody" })).ok, false);
      assert.deepEqual(bus.written, [{ stream: "commands", fields: { json: '{"verb":"assign","issue":7,"role":"builder"}' } }]);
    } finally {
      bound.stop();
    }
  });
});
