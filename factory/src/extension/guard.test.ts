// The test-first guard (ADR-044), driven as the loop drives it: an edit
// asks, a run reports, done asks. Each rule of the decision has a scenario
// that is refused and one that is allowed, and the refusal names the next
// step. The model in models/tdd-guard.qnt is the same machine.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Guard } from "./guard.js";

const python = { files: ["**/*_test.py", "tests/**"], source: ["src/**"], command: ["pytest", "python -m pytest"] };
const cwd = "/work/acme";

describe("classifying what the agent touches", () => {
  it("names a test file, a source file, and a free file, from paths relative to the worktree or absolute under it", () => {
    const g = new Guard(python, cwd);
    assert.equal(g.classify("tests/test_invoice.py"), "test");
    assert.equal(g.classify("/work/acme/src/invoice_test.py"), "test");
    assert.equal(g.classify("src/invoice.py"), "source");
    assert.equal(g.classify("/work/acme/src/billing/invoice.py"), "source");
    assert.equal(g.classify("docs/GLOSSARY.md"), "free");
    assert.equal(g.classify("pyproject.toml"), "free");
  });

  it("recognises a test run by the first words of any command segment", () => {
    const g = new Guard(python, cwd);
    assert.ok(g.isTestRun("pytest -q tests/"));
    assert.ok(g.isTestRun("cd src && python -m pytest -x"));
    assert.ok(g.isTestRun("ruff check . ; pytest"));
    assert.ok(!g.isTestRun("pytestx"));
    assert.ok(!g.isTestRun("cat tests/test_invoice.py"));
  });

  it("is inactive when the specialists declared nothing, and then refuses nothing", () => {
    const g = new Guard({ files: [], source: [], command: [] }, cwd);
    assert.equal(g.active, false);
    assert.equal(g.edit("src/anything.py"), null);
    assert.equal(g.outcome("done"), null);
  });
});

describe("the four rules", () => {
  it("refuses a source edit before any run in the session, and allows the test edit that starts the cycle", () => {
    const g = new Guard(python, cwd);
    const refusal = g.edit("src/invoice.py");
    assert.equal(refusal?.rule, "run-before-code");
    assert.match(refusal?.reason ?? "", /run the tests/);
    assert.equal(g.edit("tests/test_invoice.py"), null);
  });

  it("refuses a source edit after a test edit until a run has seen the test, whatever its verdict", () => {
    const g = new Guard(python, cwd);
    g.ran(false);
    assert.equal(g.edit("tests/test_invoice.py"), null);
    assert.equal(g.edit("src/invoice.py")?.rule, "see-it-fail-first");
    g.ran(true);
    assert.equal(g.edit("src/invoice.py"), null);
  });

  it("allows as many source edits as it takes while red, and one between runs once green", () => {
    const g = new Guard(python, cwd);
    g.ran(true);
    assert.equal(g.edit("src/invoice.py"), null);
    assert.equal(g.edit("src/invoice.py")?.rule, "run-between-steps");
    g.ran(true);
    assert.equal(g.edit("src/invoice.py"), null);
    assert.equal(g.edit("src/tax.py")?.rule, "run-between-steps");
    g.ran(false);
    assert.equal(g.edit("src/invoice.py"), null);
    assert.equal(g.edit("src/invoice.py"), null);
    assert.equal(g.edit("src/tax.py"), null);
  });

  it("refuses done until the last run after the last edit passed; blocked and failed are never refused", () => {
    const g = new Guard(python, cwd);
    assert.equal(g.outcome("done")?.rule, "done-is-green");
    assert.equal(g.outcome("blocked"), null);
    assert.equal(g.outcome("failed"), null);
    g.ran(false);
    assert.equal(g.outcome("done")?.rule, "done-is-green");
    g.ran(true);
    assert.equal(g.outcome("done"), null);
    g.edit("src/invoice.py");
    assert.equal(g.outcome("done")?.rule, "done-is-green");
    g.ran(true);
    g.edit("tests/test_invoice.py");
    assert.equal(g.outcome("done")?.rule, "done-is-green");
    g.ran(true);
    assert.equal(g.outcome("done"), null);
  });

  it("lets a free file be edited at any point without moving the machine", () => {
    const g = new Guard(python, cwd);
    assert.equal(g.edit("docs/architecture.md"), null);
    assert.equal(g.edit("src/invoice.py")?.rule, "run-before-code");
    g.ran(true);
    g.edit("src/invoice.py");
    assert.equal(g.edit("README.md"), null);
    assert.equal(g.edit("src/invoice.py")?.rule, "run-between-steps");
  });

  it("says in every refusal what to do next", () => {
    const g = new Guard(python, cwd);
    for (const r of [g.edit("src/a.py"), (g.ran(true), g.edit("src/a.py"), g.edit("src/b.py")), g.outcome("done")]) {
      assert.ok(r, "a refusal");
      assert.ok(r.reason.length > 20 && /test/.test(r.reason), r.reason);
    }
  });
});
