// A role with no model behind it: the same actor, bus and board as the pi
// extension (extension/bind.ts), driven by a script where pi would be. It
// takes an assignment, commits one file on its branch, reports the outcome
// the environment names, and ends, so the factory around it can be run on
// a host with no cage and no credential (tests/system/journey.sh).
//
// Environment, beyond what the executor sets for any session:
//   CAGEWORKS_CLONE              the clone the role's branch is made in
//   CAGEWORKS_FAKE_OUTCOME       done (default), done-without-commit, failed, blocked
//   CAGEWORKS_FAKE_OUTCOME_FILE  a file read at each task, whose word wins
//                                over the variable, so a harness can change
//                                the script between tasks of one session
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bindActor, fromEnvironment, type Bound } from "../extension/bind.js";
import { workBranch } from "../executor/core.js";

type Script = "done" | "done-without-commit" | "failed" | "blocked";

const world = fromEnvironment();
const clone = process.env["CAGEWORKS_CLONE"] ?? "";
const branch = workBranch(world.role);

function script(): Script {
  const file = process.env["CAGEWORKS_FAKE_OUTCOME_FILE"];
  if (file) {
    try {
      const word = readFileSync(file, "utf8").trim();
      if (word) return word as Script;
    } catch {
      // no file yet: the variable says
    }
  }
  return (process.env["CAGEWORKS_FAKE_OUTCOME"] ?? "done") as Script;
}

function git(args: string[], cwd = clone): string {
  return execFileSync("git", ["-c", "commit.gpgsign=false", "-c", `user.name=${world.role}`, "-c", `user.email=${world.role}@factory.invalid`, ...args], { cwd, encoding: "utf8" });
}

/** One commit on the role's branch, made in a worktree that lives for the commit. */
function commitOne(issue: number): void {
  if (git(["branch", "--list", branch]).trim() === "") git(["branch", branch, world.baseBranch]);
  const dir = mkdtempSync(join(tmpdir(), "fake-actor-"));
  try {
    git(["worktree", "add", "--detach", dir, branch]);
    writeFileSync(join(dir, `${world.role}-${issue}.txt`), `task #${issue}, by the scripted ${world.role}\n`);
    git(["add", "-A"], dir);
    git(["commit", "-q", "-m", `task #${issue}: work by ${world.role}`], dir);
    git(["update-ref", `refs/heads/${branch}`, git(["rev-parse", "HEAD"], dir).trim()]);
  } finally {
    git(["worktree", "remove", "--force", dir]);
    rmSync(dir, { recursive: true, force: true });
  }
}

let bound: Bound;

async function work(): Promise<void> {
  const actor = bound.actor;
  if (actor.state.kind !== "working") return;
  const { issue } = actor.state;
  const outcome = script();
  await actor.publish("turn_start", { issue });
  if (outcome === "done") commitOne(issue);
  await actor.publish("tool_call", { toolName: "git", issue });
  switch (outcome) {
    case "done":
    case "done-without-commit":
      await actor.reportOutcome({ status: "done", summary: `scripted: task #${issue} done` });
      break;
    case "failed":
      await actor.reportOutcome({ status: "failed", summary: `scripted: task #${issue} failed` });
      break;
    case "blocked":
      await actor.reportOutcome({ status: "blocked", summary: `scripted: task #${issue} waits` });
      break;
  }
  await actor.updateMemory(`last task: #${issue} (${outcome})`);
  await actor.share(`${world.role} finished #${issue} as ${outcome}`);
  await actor.publish("turn_end", { issue });
  await actor.settled();
}

bound = bindActor({
  ...world,
  agent: {
    prompt: () => void work().catch((e) => process.stderr.write(`fake actor: ${String(e)}\n`)),
    steer: (text) => process.stderr.write(`fake actor: steered: ${text}\n`),
    abort: () => {
      void bound.actor.reportOutcome({ status: "failed", summary: "aborted" }).then(() => bound.actor.settled());
    },
    finish: () => {
      bound.stop();
      process.exit(0);
    },
  },
  checks: {
    async hasCommit() {
      try {
        return Number(git(["rev-list", "--count", `${world.baseBranch}..${branch}`]).trim()) > 0;
      } catch {
        return false;
      }
    },
  },
});

bound.start().catch((e) => {
  process.stderr.write(`fake actor: ${String(e)}\n`);
  process.exit(1);
});
