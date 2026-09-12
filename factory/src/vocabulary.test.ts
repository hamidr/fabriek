// The six verbs the decider may speak and the executor validates (ADR-034
// point 3). What is checked here is the shape: every argument present, of
// the right kind, and every name one the rest of the system would accept.
// Whether a role exists or provides a capability is the executor's check,
// against the declaration, and lives beside it.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parseCommand, CommandError } from "./vocabulary.js";

describe("the decider's vocabulary", () => {
  it("given an assign naming an issue and a role, the command is that assign", () => {
    const c = parseCommand({ verb: "assign", issue: 7, role: "builder" });
    assert.deepEqual(c, { verb: "assign", issue: 7, role: "builder" });
  });

  it("given a retry, only the issue is named, because retry goes back to the same role", () => {
    assert.deepEqual(parseCommand({ verb: "retry", issue: 7 }), { verb: "retry", issue: 7 });
    assert.throws(() => parseCommand({ verb: "retry", issue: 7, role: "builder" }), /retry.*role/);
  });

  it("given a block, the issue and what it waits on are both issues", () => {
    assert.deepEqual(parseCommand({ verb: "block", issue: 7, on: 3 }), { verb: "block", issue: 7, on: 3 });
    assert.throws(() => parseCommand({ verb: "block", issue: 7, on: 7 }), /itself/);
  });

  it("given a file, the title and body are files and the stage is a name, never prose on argv", () => {
    const c = parseCommand({ verb: "file", titleFile: "/run/x/title", bodyFile: "/run/x/body", stage: "design" });
    assert.equal(c.verb, "file");
    assert.throws(() => parseCommand({ verb: "file", title: "Do the thing", bodyFile: "/x", stage: "design" }), /title/);
    assert.throws(() => parseCommand({ verb: "file", bodyFile: "/x", stage: "design" }), /titleFile/);
    assert.throws(() => parseCommand({ verb: "file", titleFile: "x", bodyFile: "/x", stage: "design" }), /absolute/);
  });

  it("given a push or a stop, a role is named and nothing else", () => {
    assert.deepEqual(parseCommand({ verb: "push", role: "builder" }), { verb: "push", role: "builder" });
    assert.deepEqual(parseCommand({ verb: "stop", role: "builder" }), { verb: "stop", role: "builder" });
    assert.throws(() => parseCommand({ verb: "stop", role: "builder", issue: 1 }), /stop.*issue/);
  });

  it("when the verb is not one of the six, the command is refused by that word", () => {
    assert.throws(() => parseCommand({ verb: "merge", issue: 1 }), (e: unknown) =>
      e instanceof CommandError && /merge/.test(e.message));
    assert.throws(() => parseCommand({ verb: "record", issue: 1 }), /record/);
  });

  it("when an issue is not a positive integer, the command is refused", () => {
    assert.throws(() => parseCommand({ verb: "assign", issue: "7", role: "builder" }), /issue/);
    assert.throws(() => parseCommand({ verb: "assign", issue: 0, role: "builder" }), /issue/);
    assert.throws(() => parseCommand({ verb: "assign", issue: 1.5, role: "builder" }), /issue/);
  });

  it("when a role name could reach a path, a ref or an interface, the command is refused", () => {
    assert.throws(() => parseCommand({ verb: "assign", issue: 1, role: "../etc" }), /role/);
    assert.throws(() => parseCommand({ verb: "assign", issue: 1, role: "a-role-of-thirteen" }), /12/);
    assert.throws(() => parseCommand({ verb: "push", role: "" }), /role/);
  });

  it("when a command carries a key the verb does not take, it is refused rather than trimmed", () => {
    assert.throws(() => parseCommand({ verb: "assign", issue: 1, role: "builder", brief: "do it" }), /brief/);
  });

  it("when the command is not an object at all, it is refused", () => {
    assert.throws(() => parseCommand("assign 1 builder"), CommandError);
    assert.throws(() => parseCommand(null), CommandError);
  });
});
