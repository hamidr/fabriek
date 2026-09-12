// The relay's line (ADR-039 point 2): one JSON object per line, the stream,
// the entry's id and its flat fields, exactly as the bus holds them. The
// fixture is the contract: the relay must produce every line in it and the
// client must read every line in it, and both sides run this same file.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { encodeLine, parseLine, streamsFor, type Line } from "./format.js";

const fixtures = JSON.parse(readFileSync(new URL("./fixtures.json", import.meta.url), "utf8")) as Line[];

describe("the relay's lines", () => {
  it("every fixture encodes to one line with no newline in it and parses back to itself", () => {
    for (const f of fixtures) {
      const line = encodeLine(f.stream, { id: f.id, fields: f.fields });
      assert.equal(line.includes("\n"), false);
      assert.deepEqual(parseLine(line), f);
    }
  });

  it("a line that is not a relay line is refused, naming what it lacks", () => {
    assert.throws(() => parseLine("{}"), /stream/);
    assert.throws(() => parseLine('{"stream":"x","id":"1-0"}'), /fields/);
    assert.throws(() => parseLine("not json"), /JSON/);
  });

  it("the streams relayed for a declaration are every actor's, the executor's, the decider's and the machine's", () => {
    const s = streamsFor(["builder", "reviewer"]);
    for (const name of ["control:builder", "mailbox:builder", "events:builder", "findings:builder", "control:reviewer", "commands", "operator", "events:executor", "probes", "mailbox:decider"]) {
      assert.ok(s.includes(name), `relays ${name}`);
    }
  });
});
