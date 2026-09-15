// The declaration as the machine carries it (ADR-040): read from
// /etc/fabriek/declaration.json, already validated and clamped by the
// build. What is typed here is what the executor's checks read: which roles
// exist, what each provides, which stages a workflow has and what each
// needs, and the limits. The shape is the same table modules/repo-declaration.sh
// validates; this only refuses what that table could not have produced.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readDeclaration, capableRoles, stageOf, DeclarationError } from "./declaration.js";

const acme = {
  name: "acme",
  roles: {
    builder: { command: ["pi"], provides: ["build", "test"] },
    reviewer: { command: ["pi"], provides: ["review"] },
  },
  workflows: {
    ship: { stages: [{ needs: "build" }, { needs: "test" }, { needs: "review" }], budget: { runs: 10 } },
  },
  resources: { taskAttempts: 3, tokens: 500000 },
};

describe("the declaration on the machine", () => {
  it("given the file the build wrote, roles and workflows are read as declared", () => {
    const d = readDeclaration(JSON.stringify(acme));
    assert.deepEqual(Object.keys(d.roles), ["builder", "reviewer"]);
    assert.deepEqual(d.workflows.ship?.stages.map((s: { needs: string }) => s.needs), ["build", "test", "review"]);
    assert.equal(d.resources.taskAttempts, 3);
  });

  it("the roles capable of a stage are those providing what it needs, in declaration order", () => {
    const d = readDeclaration(JSON.stringify(acme));
    assert.deepEqual(capableRoles(d, "test"), ["builder"]);
    assert.deepEqual(capableRoles(d, "review"), ["reviewer"]);
    assert.deepEqual(capableRoles(d, "design"), []);
  });

  it("a stage is found by its workflow and its label, which is its capability", () => {
    const d = readDeclaration(JSON.stringify(acme));
    assert.deepEqual(stageOf(d, "ship", "test"), { workflow: "ship", index: 1, needs: "test", next: "review", verdict: false });
    assert.deepEqual(stageOf(d, "ship", "review"), { workflow: "ship", index: 2, needs: "review", next: null, verdict: false });
    assert.equal(stageOf(d, "ship", "deploy"), null);
  });

  it("a stage declared verdict says so where the executor reads it, and one not declared does not", () => {
    const d = readDeclaration(JSON.stringify({ ...acme, workflows: { ship: { stages: [{ needs: "build" }, { needs: "review", verdict: true }] } } }));
    assert.equal(stageOf(d, "ship", "review")?.verdict, true);
    assert.equal(stageOf(d, "ship", "build")?.verdict, false);
  });

  it("a replicas key on a role is refused, because the build expands replicas before the file is written (ADR-053)", () => {
    const text = JSON.stringify({ ...acme, roles: { ...acme.roles, builder: { ...acme.roles.builder, replicas: 2 } } });
    assert.throws(() => readDeclaration(text), (e: unknown) => e instanceof DeclarationError && /builder.*replicas/.test(String(e)));
  });

  it("a role that names no command runs pi (ADR-029) and is read as declared", () => {
    const d = readDeclaration(JSON.stringify({ ...acme, roles: { architect: { provides: ["design"], specialists: ["architect"] } } }));
    assert.deepEqual(Object.keys(d.roles), ["architect"]);
    assert.equal(d.roles.architect?.command, undefined);
  });

  it("a file that is not a declaration is refused, naming what is wrong", () => {
    assert.throws(() => readDeclaration("{not json"), DeclarationError);
    assert.throws(() => readDeclaration(JSON.stringify({ name: "acme" })), /roles/);
    assert.throws(() => readDeclaration(JSON.stringify({ ...acme, roles: { "../x": acme.roles.builder } })), /role/);
  });

  it("limits absent from the file take the defaults the shell side has", () => {
    const d = readDeclaration(JSON.stringify({ ...acme, resources: {} }));
    assert.equal(d.resources.taskAttempts, 3);
    assert.equal(d.resources.tokens, 0);
  });
});
