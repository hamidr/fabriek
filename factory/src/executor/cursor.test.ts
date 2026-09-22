// Where the executor resumes reading the operator's stream: an intervention
// filed while the executor was down or still reconciling used to be dropped,
// since every stream was read from its tail at start (found on a host
// 2026-09-22: a goal filed right after up, which restarts the executor, never
// became an issue). The cursor is kept beside the state; without one the tail
// is where reading starts, as before.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resumeFrom, remember } from "./cursor.js";

describe("the operator stream's cursor", () => {
  it("given no cursor kept, reading starts where the caller says, which is the tail", () => {
    const dir = mkdtempSync(join(tmpdir(), "cursor-"));
    assert.equal(resumeFrom(join(dir, "operator"), "1790070000000-0"), "1790070000000-0");
  });

  it("given an id remembered, reading resumes from it and not from the tail", () => {
    const dir = mkdtempSync(join(tmpdir(), "cursor-"));
    const file = join(dir, "operator");
    remember(file, "1790070454060-0");
    assert.equal(readFileSync(file, "utf8").trim(), "1790070454060-0");
    assert.equal(resumeFrom(file, "1790070999999-0"), "1790070454060-0");
  });

  it("a cursor is written whole or not at all, never half", () => {
    const dir = mkdtempSync(join(tmpdir(), "cursor-"));
    const file = join(dir, "operator");
    remember(file, "1-0");
    remember(file, "2-0");
    assert.equal(resumeFrom(file, "$"), "2-0");
    assert.equal(existsSync(`${file}.new`), false);
  });
});
