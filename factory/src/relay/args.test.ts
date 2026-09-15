// What the relay is told on argv: where to read from, and which streams.
// A watcher after one stream on a bus holding thousands of probe lines
// otherwise waits through every other stream first.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { relayArgs } from "./args.js";

const all = ["control:builder", "events:builder", "events:executor", "probes"];

describe("the relay's arguments", () => {
  it("given nothing, then it reads every stream from the end", () => {
    assert.deepEqual(relayArgs([], all), { from: "$", streams: all });
  });

  it("given --from, then every stream is read from that id", () => {
    assert.deepEqual(relayArgs(["--from", "0-0"], all), { from: "0-0", streams: all });
  });

  it("given --stream, once or more, then only those streams are read, in the order given", () => {
    assert.deepEqual(relayArgs(["--stream", "events:executor", "--from", "7-0", "--stream", "probes"], all), {
      from: "7-0",
      streams: ["events:executor", "probes"],
    });
  });

  it("a stream the declaration does not relay is refused by name", () => {
    assert.throws(() => relayArgs(["--stream", "events:nobody"], all), /events:nobody/);
  });

  it("a flag with no value, or an unknown flag, is refused", () => {
    assert.throws(() => relayArgs(["--from"], all), /--from/);
    assert.throws(() => relayArgs(["--tail"], all), /--tail/);
  });
});
