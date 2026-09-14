// The TUI's hold on the relay: a watch that ends is started again after a
// pause, and the picture starts over with it, because a fresh relay replays
// from wherever it is told and nothing folded before it is still true.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { keepWatching } from "./watch.js";

function child() {
  const stdout = new PassThrough();
  const events = new EventEmitter();
  return {
    stdout,
    on: (event: "exit", cb: (code: number | null) => void) => events.on(event, cb),
    say: (line: string) => stdout.write(line + "\n"),
    end: (code: number) => {
      stdout.end();
      events.emit("exit", code);
    },
  };
}

const tick = () => new Promise((r) => setImmediate(r));

describe("keeping a watch", () => {
  it("given the watch ends, then it is started again after a pause and the picture starts over", async () => {
    const children = [child(), child()];
    const spawned: number[] = [];
    const lines: string[] = [];
    const starts: number[] = [];
    const notices: string[] = [];
    let paused = 0;
    keepWatching({
      spawn: () => {
        spawned.push(1);
        return children[spawned.length - 1]!;
      },
      onStart: () => starts.push(spawned.length),
      onLine: (l) => lines.push(l),
      onEnd: (code) => notices.push(`ended ${code}`),
      pause: async () => {
        paused++;
      },
    });
    children[0]!.say("a");
    await tick();
    children[0]!.end(255);
    await tick();
    await tick();
    assert.equal(spawned.length, 2);
    assert.equal(paused, 1);
    // onStart runs before each spawn: it saw 0 then 1 spawned so far
    assert.deepEqual(starts, [0, 1]);
    assert.deepEqual(notices, ["ended 255"]);
    children[1]!.say("b");
    await tick();
    assert.deepEqual(lines, ["a", "b"]);
  });

  it("given a line that is not the relay's, then it is dropped and the watch goes on", async () => {
    const c = child();
    const lines: string[] = [];
    keepWatching({
      spawn: () => c,
      onStart: () => {},
      onLine: (l) => {
        if (l === "bad") throw new Error("not a relay line");
        lines.push(l);
      },
      onEnd: () => {},
      pause: async () => {},
    });
    c.say("bad");
    c.say("good");
    await tick();
    assert.deepEqual(lines, ["good"]);
  });
});
