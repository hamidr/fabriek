// The board as the executor writes it, over a forge whose accounts carry
// the factory's name (ADR-068 point 4): the executor goes on speaking bare
// roles and the adapter is where the two names meet.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { ForgeBoard } from "./forge.js";
import type { ForgeClient, Comment } from "../forge/client.js";

interface Call {
  method: string;
  path: string;
  body: unknown;
}

function board(answer: (c: Call) => unknown, calls: Call[] = []): { board: ForgeBoard; calls: Call[] } {
  const fake = {
    async call<T>(method: string, path: string, body?: unknown): Promise<T> {
      const c = { method, path, body };
      calls.push(c);
      return answer(c) as T;
    },
    async thread(): Promise<Comment[]> {
      return [];
    },
  } as unknown as ForgeClient;
  return { board: new ForgeBoard(fake, "/repos/acme-operator/acme", "acme"), calls };
}

describe("the executor's board", () => {
  it("assigns the account the role holds on the forge, and unassigns with nobody", async () => {
    const { board: b, calls } = board(() => ({}));
    await b.assign(7, "builder");
    assert.deepEqual(calls.at(-1)?.body, { assignees: ["acme-builder"] });
    await b.assign(7, null);
    assert.deepEqual(calls.at(-1)?.body, { assignees: [] });
  });

  it("reads an assignee back as the bare role, and leaves an issue nobody holds unassigned", async () => {
    const { board: b } = board((c) =>
      c.path.endsWith("/issues/7")
        ? { number: 7, title: "t", body: null, state: "open", labels: [], assignees: [{ login: "acme-builder" }] }
        : { number: 8, title: "t", body: null, state: "open", labels: [], assignees: null },
    );
    assert.equal((await b.issue(7)).assignee, "builder");
    assert.equal((await b.issue(8)).assignee, null);
  });
});
