// The TUI's state, folded from relay lines (ADR-039). Pure: fold(state, line)
// returns the next state and touches nothing else, so a session can be
// replayed from --from 0-0 and the same picture comes out.
import { parseMessage } from "../messages.js";
export type { Line } from "../relay/format.js";
import type { Line } from "../relay/format.js";

export interface RoleView {
  state: "unknown" | "idle" | "working" | "blocked";
  issue?: number;
  last: string;
  /** The loop's test-first guard (ADR-044) on this task: the last refusal,
   *  how many since the task began, and how many times in a row the same
   *  rule hit the same path. A correct loop refuses a little every task;
   *  a repeat is what the operator acts on. */
  guard?: { rule: string; path: string; count: number; repeats: number };
}

export interface BoardIssue {
  number: number;
  title: string;
  stage: string | null;
  assignee: string | null;
  blocked: boolean;
}

/** One thing the factory did, as the operator reads it: who, and what. */
export interface Activity {
  /** The bus's id, which orders it: the relay replays one stream after another. */
  id: string;
  by: string;
  text: string;
}

export interface State {
  roles: Record<string, RoleView>;
  board: BoardIssue[];
  ready: string[];
  routing: boolean;
  findings: { role: string; text: string }[];
  commands: { by: "decider" | "executor" | "operator"; text: string }[];
  /** Commands and findings as they came, one list, newest last. */
  activity: Activity[];
  /** What each role did, in the operator's words, newest last. */
  stream: Record<string, string[]>;
  spend: Record<string, number>;
  probes: string[];
}

const KEEP = 50;
const STREAM_KEEP = 200;

export function initial(roles: string[]): State {
  return {
    roles: Object.fromEntries(roles.map((r) => [r, { state: "unknown", last: "" }])),
    board: [],
    ready: [],
    routing: true,
    findings: [],
    commands: [],
    activity: [],
    stream: {},
    spend: {},
    probes: [],
  };
}

function keep<T>(list: T[], item: T, max = KEEP): T[] {
  const out = [...list, item];
  return out.length > max ? out.slice(out.length - max) : out;
}

/** One line of a text that may hold several: the first, marked as cut. A
 *  newline inside a pane's line breaks the pane it is drawn in. */
function firstLine(text: string): string {
  const [head, ...rest] = text.split("\n");
  return rest.some((l) => l.trim().length > 0) ? `${head ?? ""} ~` : (head ?? "");
}

/** The role's stream with one more line. */
function said(s: State, role: string, text: string): State {
  return { ...s, stream: { ...s.stream, [role]: keep(s.stream[role] ?? [], firstLine(text), STREAM_KEEP) } };
}

/** Where a bus id sorts: milliseconds, then the sequence within them. */
function idOrder(a: string, b: string): number {
  const [am, as] = a.split("-").map(Number) as [number, number];
  const [bm, bs] = b.split("-").map(Number) as [number, number];
  return am - bm || as - bs;
}

function did(s: State, id: string, by: string, text: string): State {
  const activity = [...s.activity, { id, by, text }].sort((x, y) => idOrder(x.id, y.id));
  return { ...s, activity: activity.length > KEEP ? activity.slice(activity.length - KEEP) : activity };
}

/** A tool call as one line: the tool, then the one argument that says what it touched. */
function toolLine(payload: Record<string, unknown>): string {
  const tool = String(payload["toolName"] ?? "tool");
  const input = (payload["input"] ?? {}) as Record<string, unknown>;
  const what = ["command", "path", "pattern", "query", "url"].map((k) => input[k]).find((v) => typeof v === "string") as string | undefined;
  return what ? `${tool}  ${firstLine(what)}` : tool;
}

/** What the assistant said in a turn, its thinking left out. */
function saidText(payload: Record<string, unknown>): string {
  const message = payload["message"] as { content?: unknown } | undefined;
  const content = Array.isArray(message?.content) ? (message.content as { type?: string; text?: string }[]) : [];
  return content
    .filter((c) => c.type === "text" && typeof c.text === "string")
    .map((c) => (c.text as string).trim())
    .filter((t) => t.length > 0)
    .join("\n");
}

function tryJson(text: string | undefined): unknown {
  try {
    return JSON.parse(text ?? "");
  } catch {
    return null;
  }
}

function describeCommand(c: unknown): string {
  if (typeof c !== "object" || c === null) return String(c);
  const o = c as Record<string, unknown>;
  // The decider's commands say verb; the operator's entries say op.
  const rest = Object.entries(o)
    .filter(([k]) => k !== "verb" && k !== "op")
    .map(([, v]) => String(v));
  return [String(o["verb"] ?? o["op"] ?? "?"), ...rest].join(" ");
}

export function fold(s: State, line: Line): State {
  const [kind, name] = line.stream.split(":", 2) as [string, string | undefined];
  const role = name ?? "";
  const view = (r: string): RoleView => s.roles[r] ?? { state: "unknown", last: "" };
  const withRole = (r: string, v: RoleView): State => ({ ...s, roles: { ...s.roles, [r]: v } });

  switch (kind) {
    case "control": {
      let m;
      try {
        m = parseMessage(line.fields);
      } catch {
        return withRole(role, { ...view(role), last: `malformed ${line.fields["kind"] ?? ""}` });
      }
      if (m.kind === "ready") return withRole(role, { state: "idle", last: "ready" });
      if (m.kind === "ack") return withRole(role, { state: "working", issue: m.issue, last: `ack #${m.issue}` });
      if (m.kind === "held") return withRole(role, { ...view(role), last: `holds ${m.issues.map((i) => `#${i}`).join(" ") || "nothing"}` });
      return s;
    }
    case "events": {
      if (role === "executor") return foldExecutor(s, line);
      const payload = tryJson(line.fields["json"]) as Record<string, unknown> | null;
      const eventName = line.fields["name"] ?? "event";
      if (eventName === "guard_refused") {
        const rule = String(payload?.["rule"] ?? "");
        const path = typeof payload?.["path"] === "string" ? payload["path"] : "";
        const before = view(role).guard;
        const same = before !== undefined && before.rule === rule && before.path === path;
        const guard = { rule, path, count: (before?.count ?? 0) + 1, repeats: same ? before.repeats + 1 : 1 };
        const next = withRole(role, { ...view(role), guard, last: `guard ${rule}${path ? ` ${path}` : ""}` });
        return said(next, role, `guard refused ${rule}${path ? ` on ${path}` : ""}`);
      }
      const tool = payload && typeof payload["toolName"] === "string" ? ` ${payload["toolName"]}` : "";
      const next = withRole(role, { ...view(role), last: `${eventName}${tool}` });
      if (eventName === "turn_start" && payload) return said(next, role, `turn ${Number(payload["turnIndex"] ?? 0) + 1}`);
      if (eventName === "tool_call" && payload) return said(next, role, toolLine(payload));
      if (eventName === "turn_end" && payload) {
        const text = saidText(payload);
        return text ? said(next, role, text) : next;
      }
      return next;
    }
    case "findings": {
      const text = line.fields["text"] ?? "";
      const next = { ...s, findings: keep(s.findings, { role, text }) };
      return said(did(next, line.id, role, text), role, `finding: ${text}`);
    }
    case "commands": {
      const text = describeCommand(tryJson(line.fields["json"]));
      return did({ ...s, commands: keep(s.commands, { by: "decider", text }) }, line.id, "decider", text);
    }
    case "operator": {
      const text = describeCommand(tryJson(line.fields["json"]));
      return did({ ...s, commands: keep(s.commands, { by: "operator", text }) }, line.id, "operator", text);
    }
    case "probes": {
      // The role is the machine's word on whose uid it was; none means no role's.
      const who = line.fields["role"] ? `${line.fields["role"]}  ` : "";
      return { ...s, probes: keep(s.probes, `${who}${line.fields["event"] ?? ""}`) };
    }
    case "mailbox": {
      const m = tryJson(JSON.stringify(line.fields)) as Record<string, string> | null;
      if (m?.["kind"] === "assignment") return withRole(role, { ...view(role), last: `assigned #${m["issue"]}` });
      if (m?.["kind"] === "steer") return said(s, role, `operator: ${m["text"] ?? ""}`);
      return s;
    }
    default:
      return s;
  }
}

function foldExecutor(s: State, ln: Line): State {
  const payload = tryJson(ln.fields["json"]) as Record<string, unknown> | null;
  switch (ln.fields["name"]) {
    case "board": {
      if (!payload) return s;
      const issues = (payload["issues"] as BoardIssue[] | undefined) ?? [];
      const roles = { ...s.roles };
      for (const i of issues) {
        if (i.assignee && i.blocked && roles[i.assignee]) roles[i.assignee] = { ...roles[i.assignee]!, state: "blocked", issue: i.number };
      }
      return { ...s, roles, board: issues, ready: (payload["ready"] as string[] | undefined) ?? [], routing: payload["routing"] !== false };
    }
    case "spend":
      return { ...s, spend: (payload as Record<string, number> | null) ?? {} };
    case "command": {
      if (!payload) return s;
      const result = payload["result"] as { ok: boolean; reason?: string } | undefined;
      const text = describeCommand(payload["command"]);
      const line = result?.ok ? `did ${text}` : `refused ${text}: ${result?.reason ?? ""}`;
      return did({ ...s, commands: keep(s.commands, { by: "executor", text: line }) }, ln.id, "executor", line);
    }
    default:
      return s;
  }
}
