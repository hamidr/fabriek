import { test } from "node:test";
import assert from "node:assert/strict";
import { accountOf, roleOf } from "./account.js";

test("a role's account on the forge is its factory's name and its own", () => {
  assert.equal(accountOf("acme", "dev"), "acme-dev");
  assert.equal(accountOf("acme", "decider"), "acme-decider");
});

test("a login of this factory reads back as the bare role the cores speak", () => {
  assert.equal(roleOf("acme", "acme-dev"), "dev");
  assert.equal(roleOf("acme", "acme-decider"), "decider");
});

test("a login of another factory or of a person is left as it is", () => {
  assert.equal(roleOf("acme", "widgets-dev"), "widgets-dev");
  assert.equal(roleOf("acme", "acme-operator"), "operator");
  assert.equal(roleOf("acme", "someone"), "someone");
});

test("a role whose name starts with the factory's keeps the whole of its own name", () => {
  assert.equal(roleOf("acme", "acme-acme-dev"), "acme-dev");
});
