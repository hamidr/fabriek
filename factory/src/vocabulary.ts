// The six verbs the decider may speak (ADR-034 point 3). A command is data:
// it arrives as JSON on the bus, is parsed into exactly one of these shapes
// or refused with the reason, and is then validated against the declaration
// and the board by the executor, which is the only thing that acts on it.
//
// No verb merges and no verb records. Retry names no role, because a task
// sticks to the role that took it (ADR-015 point 4). File takes files and
// never prose, because nothing a role or the decider writes reaches a command
// line.
import { isIssue, isName, isRoleName, ROLE_NAME_MAX } from "./names.js";

export type Command =
  | { verb: "assign"; issue: number; role: string }
  | { verb: "retry"; issue: number }
  | { verb: "block"; issue: number; on: number }
  | { verb: "file"; titleFile: string; bodyFile: string; stage: string }
  | { verb: "push"; role: string }
  | { verb: "stop"; role: string };

export type Verb = Command["verb"];
export const VERBS: readonly Verb[] = ["assign", "retry", "block", "file", "push", "stop"];

export class CommandError extends Error {
  override name = "CommandError";
}

/** The keys each verb takes, and no others. */
const SHAPE: Record<Verb, readonly string[]> = {
  assign: ["issue", "role"],
  retry: ["issue"],
  block: ["issue", "on"],
  file: ["titleFile", "bodyFile", "stage"],
  push: ["role"],
  stop: ["role"],
};

function refuse(message: string): never {
  throw new CommandError(message);
}

function issue(o: Record<string, unknown>, key: string): number {
  const v = o[key];
  if (!isIssue(v)) refuse(`${key} must be a positive integer issue number`);
  return v;
}

function role(o: Record<string, unknown>): string {
  const v = o["role"];
  if (!isName(v)) refuse("role must be a usable name");
  if (!isRoleName(v)) refuse(`role must be at most ${ROLE_NAME_MAX} characters`);
  return v;
}

function file(o: Record<string, unknown>, key: string): string {
  const v = o[key];
  if (typeof v !== "string" || v.length === 0) refuse(`${key} must name a file`);
  if (!v.startsWith("/")) refuse(`${key} must be an absolute path`);
  return v;
}

/** One command out of anything, or a CommandError saying what was wrong. */
export function parseCommand(input: unknown): Command {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    refuse("a command is an object with a verb");
  }
  const o = input as Record<string, unknown>;
  const verb = o["verb"];
  if (typeof verb !== "string" || !(VERBS as readonly string[]).includes(verb)) {
    refuse(`not a verb of the vocabulary: ${String(verb)}`);
  }
  const v = verb as Verb;
  for (const key of Object.keys(o)) {
    if (key !== "verb" && !SHAPE[v].includes(key)) refuse(`${v} does not take ${key}`);
  }
  for (const key of SHAPE[v]) {
    if (!(key in o)) refuse(`${v} needs ${key}`);
  }
  switch (v) {
    case "assign":
      return { verb: v, issue: issue(o, "issue"), role: role(o) };
    case "retry":
      return { verb: v, issue: issue(o, "issue") };
    case "block": {
      const a = issue(o, "issue");
      const b = issue(o, "on");
      if (a === b) refuse("an issue cannot block on itself");
      return { verb: v, issue: a, on: b };
    }
    case "file": {
      const stage = o["stage"];
      if (!isName(stage)) refuse("stage must be a usable name");
      return { verb: v, titleFile: file(o, "titleFile"), bodyFile: file(o, "bodyFile"), stage };
    }
    case "push":
      return { verb: v, role: role(o) };
    case "stop":
      return { verb: v, role: role(o) };
  }
}
