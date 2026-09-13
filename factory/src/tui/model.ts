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
}

export interface BoardIssue {
  number: number;
  title: string;
  stage: string | null;
  assignee: string | null;
  blocked: boolean;
}

export interface State {
  roles: Record<string, RoleView>;
  board: BoardIssue[];
  ready: string[];
  routing: boolean;
  findings: { role: string; text: string }[];
  commands: { by: "decider" | "executor" | "operator"; text: string }[];
  spend: Record<string, number>;
  probes: string[];
}

const KEEP = 50;

export function initial(roles: string[]): State {
  return {
    roles: Object.fromEntries(roles.map((r) => [r, { state: "unknown", last: "" }])),
    board: [],
    ready: [],
    routing: true,
    findings: [],
    commands: [],
    spend: {},
    probes: [],
  };
}

function keep<T>(list: T[], item: T): T[] {
  const out = [...list, item];
  return out.length > KEEP ? out.slice(out.length - KEEP) : out;
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
  const rest = Object.entries(o)
    .filter(([k]) => k !== "verb")
    .map(([, v]) => String(v));
  return [String(o["verb"] ?? "?"), ...rest].join(" ");
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
      const tool = payload && typeof payload["toolName"] === "string" ? ` ${payload["toolName"]}` : "";
      return withRole(role, { ...view(role), last: `${eventName}${tool}` });
    }
    case "findings":
      return { ...s, findings: keep(s.findings, { role, text: line.fields["text"] ?? "" }) };
    case "commands":
      return { ...s, commands: keep(s.commands, { by: "decider", text: describeCommand(tryJson(line.fields["json"])) }) };
    case "operator":
      return { ...s, commands: keep(s.commands, { by: "operator", text: describeCommand(tryJson(line.fields["json"])) }) };
    case "probes": {
      // The role is the machine's word on whose uid it was; none means no role's.
      const who = line.fields["role"] ? `${line.fields["role"]}  ` : "";
      return { ...s, probes: keep(s.probes, `${who}${line.fields["event"] ?? ""}`) };
    }
    case "mailbox": {
      const m = tryJson(JSON.stringify(line.fields)) as Record<string, string> | null;
      if (m?.["kind"] === "assignment") return withRole(role, { ...view(role), last: `assigned #${m["issue"]}` });
      return s;
    }
    default:
      return s;
  }
}

function foldExecutor(s: State, line: Line): State {
  const payload = tryJson(line.fields["json"]) as Record<string, unknown> | null;
  switch (line.fields["name"]) {
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
      return { ...s, commands: keep(s.commands, { by: "executor", text: result?.ok ? `did ${text}` : `refused ${text}: ${result?.reason ?? ""}` }) };
    }
    default:
      return s;
  }
}
