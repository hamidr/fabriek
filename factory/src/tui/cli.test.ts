// What the TUI types at the launcher on the operator's behalf (ADR-039
// point 3), in the launcher's own grammar (ADR-047): one verb level, the
// factory as -f before it. Found on a console whose every key answered
// "unknown command: factory".
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { cliArgs, watchArgs } from "./cli.js";

describe("what the TUI asks the launcher", () => {
  it("given a factory and a verb, then the line is -f FACTORY VERB and the verb's own words after it", () => {
    assert.deepEqual(cliArgs("acme", "file", ["-m", "acceptance: it imports", "ship", "the importer"]), [
      "-f", "acme", "file", "-m", "acceptance: it imports", "ship", "the importer",
    ]);
    assert.deepEqual(cliArgs("acme", "mirror", []), ["-f", "acme", "mirror"]);
  });

  it("given a factory, then the watch asks for everything the bus still holds, so the board is on screen at open and not at the next tick", () => {
    assert.deepEqual(watchArgs("acme"), ["-f", "acme", "watch", "--from", "0-0"]);
  });
});
