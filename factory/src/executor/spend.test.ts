// The proxy counts by source address; the operator reads by role. The
// executor holds the plan that says which is which, so the translation is
// its and the TUI never learns an address.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spendByRole } from "./spend.js";

const cages = { builder: "10.77.0.10", reviewer: "10.77.0.11", decider: "10.77.0.2" };

describe("spend by role", () => {
  it("given the proxy's counts by address, then every cage in the plan is named by its role, the ones that spent nothing at zero", () => {
    assert.deepEqual(spendByRole({ "10.77.0.10": 120, "10.77.0.2": 30, total: 150 }, cages), {
      builder: 120,
      reviewer: 0,
      decider: 30,
      total: 150,
    });
  });

  it("given a count on an address the plan does not name, then it is kept under the address rather than hidden", () => {
    assert.deepEqual(spendByRole({ "10.77.0.99": 5, total: 5 }, cages), { builder: 0, reviewer: 0, decider: 0, "10.77.0.99": 5, total: 5 });
  });

  it("given no counts at all, then every role is at zero and the total is zero", () => {
    assert.deepEqual(spendByRole({}, cages), { builder: 0, reviewer: 0, decider: 0, total: 0 });
  });
});
