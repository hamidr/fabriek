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

/** The executor's board event, as the decider reads it off events:executor. */
function board(id: string, ready: string[], epoch = "e1"): Record<string, Entry[]> {
  return { "events:executor": [{ id, fields: { kind: "event", name: "board", json: JSON.stringify({ issues: [], ready, routing: true, epoch }) } }] };
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
    const bound = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([board("1-0", [])]), forge, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1 });
    await bound.start();
    await tick();
    bound.stop();
    assert.equal(thought.length, 1);
    assert.deepEqual(thought[0]?.issues, [{ number: 7, title: "Add importer", stage: "build", assignee: null, attempts: 1, blocked: false, lastOutcome: null }]);
    assert.deepEqual(thought[0]?.ready, []);
  });

  it("given the executor's board, then the ready set is the board's and it thinks again; a later board without the role takes it out", async () => {
    const thought: Snapshot[] = [];
    const bus = scriptedBus([board("1-0", []), board("2-0", ["builder"]), board("3-0", [])]);
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

  // Seen on a host (2026-09-30), and models/decider-ready.qnt: a stale
  // ready was assigned to and refused, the role then announced under a new
  // executor, and a decider that had thought about that same ready set
  // never thought again. A role's old ready on its control stream is not
  // the executor's.
  it("given a ready left on a role's control stream by an earlier session, then the decider does not hold that role ready", async () => {
    const thought: Snapshot[] = [];
    const bus = scriptedBus([{ "control:builder": [{ id: "1-0", fields: { kind: "ready", capabilities: "build" } }] }, board("2-0", [])]);
    const bound = bindDecider({ declaration, policy: null, connect: async () => bus, forge, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1 });
    await bound.start();
    try {
      await tick();
      assert.ok(thought.length > 0);
      assert.ok(thought.every((s) => !s.ready.includes("builder")), JSON.stringify(thought.map((s) => s.ready)));
    } finally {
      bound.stop();
    }
  });

  it("given the same ready set from an executor started again, then it thinks again, since what it asked the last one was not asked of this one", async () => {
    const thought: Snapshot[] = [];
    const bus = scriptedBus([board("1-0", ["builder"], "e1"), board("2-0", ["builder"], "e1"), board("3-0", ["builder"], "e2")]);
    const bound = bindDecider({ declaration, policy: null, connect: async () => bus, forge, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1 });
    await bound.start();
    try {
      await tick();
      assert.equal(thought.length, 2, `once per executor, not ${thought.length} times`);
    } finally {
      bound.stop();
    }
  });

  it("given no board from the executor yet, then it thinks about nothing, since it does not know who is ready", async () => {
    const thought: Snapshot[] = [];
    const bound = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([]), forge, think: async (_p, s) => void thought.push(s), tickMs: 5, retryMs: 1 });
    await bound.start();
    try {
      await tick();
      assert.equal(thought.length, 0);
    } finally {
      bound.stop();
    }
  });

  // Measured on a machine: a tick every thirty seconds with the whole board
  // in it was nine million tokens in half an hour, the factory's ceiling
  // spent by the one role that does no work.
  it("given a tick with nothing changed on the board or the ready set, then it does not think again", async () => {
    const thought: Snapshot[] = [];
    const bound = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([board("1-0", [])]), forge, think: async (_p, s) => void thought.push(s), tickMs: 5, retryMs: 1 });
    await bound.start();
    try {
      await tick();
      await tick();
      assert.equal(thought.length, 1, `thought once on an unchanged board, not ${thought.length} times`);
    } finally {
      bound.stop();
    }
  });

  it("given a tick after the board changed underneath, then it thinks once more", async () => {
    const thought: Snapshot[] = [];
    let assignee: { login: string }[] = [];
    const moving: DeciderForge = {
      ...forge,
      call: async <T,>(_method: string, path: string): Promise<T> => {
        if (path.includes("/issues?")) return [{ number: 7, title: "Add importer", labels: [{ name: "build" }], assignees: assignee }] as T;
        throw new Error(`unscripted ${path}`);
      },
    };
    const bound = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([board("1-0", [])]), forge: moving, think: async (_p, s) => void thought.push(s), tickMs: 5, retryMs: 1 });
    await bound.start();
    try {
      await tick();
      assignee = [{ login: "builder" }];
      await tick();
      await tick();
      assert.equal(thought.length, 2, `thought once more after the change, not ${thought.length} times`);
      assert.equal(thought.at(-1)?.issues[0]?.assignee, "builder");
    } finally {
      bound.stop();
    }
  });

  // The decider's process ends with each thought (index.ts) and the next
  // one starts here; what the last one thought about is kept so the new
  // process does not decide the same board again on start.
  it("given what the last process thought about, then a start on the same board thinks nothing, and on a changed board thinks", async () => {
    const thought: Snapshot[] = [];
    let remembered: string | null = null;
    const memory = { read: () => remembered, write: (s: string) => void (remembered = s) };
    const first = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([board("1-0", [])]), forge, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1, memory });
    await first.start();
    await tick();
    first.stop();
    assert.equal(thought.length, 1);
    const second = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([board("1-0", [])]), forge, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1, memory });
    await second.start();
    await tick();
    second.stop();
    assert.equal(thought.length, 1, "the same board is not thought about again by a fresh process");
    let assignee: { login: string }[] = [{ login: "builder" }];
    const moving: DeciderForge = {
      ...forge,
      call: async <T,>(_method: string, path: string): Promise<T> => {
        if (path.includes("/issues?")) return [{ number: 7, title: "Add importer", labels: [{ name: "build" }], assignees: assignee }] as T;
        throw new Error(`unscripted ${path}`);
      },
    };
    const third = bindDecider({ declaration, policy: null, connect: async () => scriptedBus([board("1-0", [])]), forge: moving, think: async (_p, s) => void thought.push(s), tickMs: 60000, retryMs: 1, memory });
    await third.start();
    await tick();
    third.stop();
    assert.equal(thought.length, 2, "a changed board is thought about by a fresh process");
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
