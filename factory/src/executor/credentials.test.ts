import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { credentialAge } from "./credentials.js";

describe("the credential's age", () => {
  const dir = mkdtempSync(join(tmpdir(), "age-"));
  const stamp = (host: string, secondsAgo: number) => {
    const file = join(dir, host);
    writeFileSync(file, "");
    const t = (Date.now() - secondsAgo * 1000) / 1000;
    utimesSync(file, t, t);
  };

  it("credential age: a credential refreshed within its maxAge is not overdue", async () => {
    stamp("gw.example.test", 600);
    assert.equal(await credentialAge({ maxAge: { "gw.example.test": 3600 }, dir }).overdue(), null);
  });

  it("credential age: one older than its maxAge is named", async () => {
    stamp("gw.example.test", 7200);
    assert.equal(await credentialAge({ maxAge: { "gw.example.test": 3600 }, dir }).overdue(), "gw.example.test");
  });

  it("credential age: one never refreshed has no stamp and is overdue", async () => {
    assert.equal(await credentialAge({ maxAge: { "never.example.test": 3600 }, dir }).overdue(), "never.example.test");
  });

  it("credential age: a host with no maxAge is never asked about", async () => {
    stamp("api.anthropic.com", 999999);
    assert.equal(await credentialAge({ maxAge: {}, dir }).overdue(), null);
  });

  it("credential age: the clock is the caller's", async () => {
    stamp("gw.example.test", 600);
    const later = () => Date.now() + 7200 * 1000;
    assert.equal(await credentialAge({ maxAge: { "gw.example.test": 3600 }, dir, now: later }).overdue(), "gw.example.test");
    rmSync(dir, { recursive: true });
  });
});
