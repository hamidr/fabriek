// The relay's loop against a scripted bus: what it prints, where it reads
// from after the bus goes away, and that it never ends on its own.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import type { Entry } from "../bus/client.js";
import { tail, type Tailed } from "./tail.js";

type Step = Record<string, Entry[]> | Error;

/** A bus connection that answers each read from a script and closes on an Error. */
function scripted(steps: Step[]): Tailed & { asked: Record<string, string>[] } {
  const asked: Record<string, string>[] = [];
  return {
    asked,
    closed: false,
    async xreadMany(after) {
      asked.push({ ...after });
      const step = steps.shift();
      if (step === undefined) return {};
      if (step instanceof Error) {
        this.closed = true;
        throw step;
      }
      return step;
    },
    close() {
      this.closed = true;
    },
  };
}

const e = (id: string): Entry => ({ id, fields: { kind: "event", name: "board" } });

async function run(clients: (Tailed | Error)[], from = "$") {
  const lines: string[] = [];
  const waits: number[] = [];
  let connects = 0;
  let reads = 0;
  await tail({
    streams: ["events:executor", "commands"],
    from,
    async connect() {
      connects++;
      const next = clients.shift();
      if (next === undefined) throw new Error("no more clients");
      if (next instanceof Error) throw next;
      return next;
    },
    write: (l) => lines.push(l),
    retry: async () => {
      waits.push(1);
    },
    until: () => ++reads >= 6,
  });
  return { lines, waits, connects };
}

describe("the relay's loop", () => {
  it("given the bus drops the connection, then it connects again and reads on from the last id it printed", async () => {
    const first = scripted([{ "events:executor": [e("1-0")] }, new Error("bus closed: connection closed")]);
    const second = scripted([{ "events:executor": [e("2-0")] }]);
    const { lines, connects } = await run([first, second]);
    assert.equal(connects, 2);
    assert.deepEqual(lines.map((l) => (JSON.parse(l) as { id: string }).id), ["1-0", "2-0"]);
    assert.deepEqual(second.asked[0], { "events:executor": "1-0", commands: "$" });
  });

  it("given the bus cannot be reached, then it waits and tries again rather than ending", async () => {
    const later = scripted([{ commands: [e("3-0")] }]);
    const { lines, waits, connects } = await run([new Error("ECONNREFUSED"), later]);
    assert.equal(connects, 2);
    assert.equal(waits.length, 1);
    assert.equal(lines.length, 1);
  });

  it("given --from, then the first read asks every stream from there", async () => {
    const c = scripted([]);
    await run([c], "0-0");
    assert.deepEqual(c.asked[0], { "events:executor": "0-0", commands: "0-0" });
  });
});
