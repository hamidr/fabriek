// Git as the executor runs it (ADR-036 points 5 and 7), for a factory whose
// roles live in a nixcage machine of its own (ADR-070): a role commits in
// the machine's clone, so what reads or pushes a role's branch runs there,
// through a command prefix; the record is written on the host, in the
// host's own clone, and pushed to the forge, where the operator fetches
// it. Real repositories; the prefix is a script that runs its words here
// and records them, standing for nixcage's machine exec.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CloneGit } from "./git.js";

function sh(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], {
    env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
  }).toString().trim();
}

function world() {
  const dir = mkdtempSync(join(tmpdir(), "git-"));
  const forge = join(dir, "forge.git");
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", forge]);
  const origin = join(dir, "origin");
  execFileSync("git", ["init", "-q", "-b", "main", origin]);
  sh(origin, "commit", "-q", "--allow-empty", "-m", "first");
  sh(origin, "push", "-q", forge, "main");
  // As fabriek_factory_clone_ensure leaves a clone: on a branch of its
  // own, so main is checked out by nothing and can be fetched into.
  const clone = join(dir, "machine-clone");
  execFileSync("git", ["clone", "-q", origin, clone]);
  sh(clone, "switch", "-q", "-c", "fabriek-clone");
  const hostClone = join(dir, "host-clone");
  execFileSync("git", ["clone", "-q", origin, hostClone]);
  sh(hostClone, "switch", "-q", "-c", "fabriek-clone");
  const token = join(dir, "token");
  writeFileSync(token, "unused\n");
  const log = join(dir, "prefix.log");
  const prefix = join(dir, "machine-exec");
  // /bin/sh: the build's sandbox has it and no /usr/bin/env.
  writeFileSync(prefix, `#!/bin/sh\nprintf '%s\\n' "$*" >>${log}\nexec "$@"\n`);
  chmodSync(prefix, 0o755);
  return { dir, forge, clone, hostClone, token, log, prefix };
}

describe("the executor's git with the roles in a machine", () => {
  it("a role's branch is read and pushed in the machine's clone, through the prefix", async () => {
    const w = world();
    sh(w.clone, "switch", "-q", "-c", "builder/work");
    sh(w.clone, "commit", "-q", "--allow-empty", "-m", "built");
    const git = new CloneGit({ clone: w.clone, forgeUrl: w.forge, forgeTokenFile: w.token, command: [w.prefix] });
    assert.equal(await git.tip("builder/work"), sh(w.clone, "rev-parse", "builder/work"));
    assert.equal(await git.commitsSince("builder/work", null), 1);
    await git.push("builder/work");
    assert.equal(sh(w.forge, "rev-parse", "builder/work"), sh(w.clone, "rev-parse", "builder/work"));
    const words = readFileSync(w.log, "utf8");
    assert.match(words, /^env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=.* git -C .*machine-clone push /m);
    assert.match(words, /git -C .*machine-clone rev-parse --verify --quiet refs\/heads\/builder\/work/);
  });

  it("the token reaches git as a word the guest's shell keeps whole, never as the value", async () => {
    const w = world();
    sh(w.clone, "switch", "-q", "-c", "builder/work");
    const git = new CloneGit({ clone: w.clone, forgeUrl: w.forge, forgeTokenFile: w.token, command: [w.prefix] });
    await git.push("builder/work");
    const words = readFileSync(w.log, "utf8");
    assert.ok(words.includes(`$(cat ${w.token})`));
    assert.ok(!words.includes("unused"));
  });

  it("the record is written in the host's clone and pushed to the forge, where the operator fetches it", async () => {
    const w = world();
    const git = new CloneGit({
      clone: w.clone, recordClone: w.hostClone, forgeUrl: w.forge, forgeTokenFile: w.token, command: [w.prefix],
      record: async () => '[{"number":1}]',
    });
    await git.mirror();
    const record = sh(w.forge, "rev-parse", "refs/fabriek/record");
    assert.equal(sh(w.forge, "show", `${record}:issues.json`), '[{"number":1}]');
    assert.equal(sh(w.hostClone, "rev-parse", "refs/fabriek/record"), record);
    // The machine's clone is only asked for merged main.
    const words = readFileSync(w.log, "utf8");
    assert.match(words, /git -C .*machine-clone fetch .*forge.git refs\/heads\/main:refs\/heads\/main/);
    assert.ok(!words.includes("update-ref"));
  });

  it("without a prefix everything runs here, in the one clone, as before", async () => {
    const w = world();
    sh(w.clone, "switch", "-q", "-c", "builder/work");
    sh(w.clone, "commit", "-q", "--allow-empty", "-m", "built");
    const git = new CloneGit({ clone: w.clone, forgeUrl: w.forge, forgeTokenFile: w.token, record: async () => "[]" });
    await git.push("builder/work");
    await git.mirror();
    assert.equal(sh(w.forge, "rev-parse", "builder/work"), sh(w.clone, "rev-parse", "builder/work"));
    assert.ok(sh(w.clone, "rev-parse", "refs/fabriek/record").length === 40);
    assert.equal(existsSync(w.log), false);
  });
});
