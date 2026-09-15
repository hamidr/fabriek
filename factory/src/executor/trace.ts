// The trace of an attempt (ADR-051): one comment in the task's thread
// saying what the attempt used, read off the events stream between the
// actor's task_started and task_ended brackets and off the probes stream in
// the same span. A summary of what ADR-038's sources already held, taken
// while they still hold it; nothing here is a fourth source.

export interface Entry {
  id: string;
  fields: Record<string, string>;
}

export interface TraceInput {
  role: string;
  issue: number;
  attempt: number;
  /** The role's events stream, oldest first. */
  events: Entry[];
  /** The probes stream, oldest first, every role's. */
  probes: Entry[];
}

const COMMAND_WIDTH = 100;

interface Event {
  id: string;
  name: string;
  payload: Record<string, unknown>;
}

function parse(e: Entry): Event | null {
  const name = e.fields["name"];
  if (e.fields["kind"] !== "event" || !name) return null;
  try {
    const payload = JSON.parse(e.fields["json"] ?? "{}") as unknown;
    return { id: e.id, name, payload: payload && typeof payload === "object" ? (payload as Record<string, unknown>) : {} };
  } catch {
    return null;
  }
}

/** Stream ids order as their numbers do, not as strings. */
function idAtMost(a: string, b: string): boolean {
  const [am, as] = a.split("-").map(Number);
  const [bm, bs] = b.split("-").map(Number);
  return am === bm ? (as ?? 0) <= (bs ?? 0) : (am ?? 0) < (bm ?? 0);
}

function count<T>(items: T[], key: (t: T) => string | null): [string, number][] {
  const counts = new Map<string, number>();
  for (const item of items) {
    const k = key(item);
    if (k !== null) counts.set(k, (counts.get(k) ?? 0) + 1);
  }
  return [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

function oneLine(command: string): string {
  const first = (command.split("\n")[0] ?? "").trim();
  return first.length > COMMAND_WIDTH ? `${first.slice(0, COMMAND_WIDTH)}...` : first;
}

/** The span between the brackets of this attempt, or null when the stream no longer holds its start. */
function span(events: Event[], issue: number, attempt: number): { from: string; to: string | null } | null {
  const isBracket = (e: Event, name: string) => e.name === name && e.payload["issue"] === issue && e.payload["attempt"] === attempt;
  const start = [...events].reverse().find((e) => isBracket(e, "task_started"));
  if (!start) return null;
  const end = events.find((e) => isBracket(e, "task_ended") && idAtMost(start.id, e.id));
  return { from: start.id, to: end?.id ?? null };
}

export function traceOf(t: TraceInput): string {
  const events = t.events.map(parse).filter((e): e is Event => e !== null);
  const s = span(events, t.issue, t.attempt);
  if (!s) return `trace: not observed; the events stream no longer holds attempt ${t.attempt} of ${t.role}`;
  const within = (id: string) => idAtMost(s.from, id) && (s.to === null || idAtMost(id, s.to));
  const seen = events.filter((e) => within(e.id));
  const calls = seen.filter((e) => e.name === "tool_call");
  const input = (e: Event) => (e.payload["input"] && typeof e.payload["input"] === "object" ? (e.payload["input"] as Record<string, unknown>) : {});
  const str = (v: unknown) => (typeof v === "string" ? v : null);

  const lines = [`trace: attempt ${t.attempt} of ${t.role}`, `turns: ${seen.filter((e) => e.name === "turn_start").length}`];
  const tools = count(calls, (e) => str(e.payload["toolName"]));
  lines.push(`tools: ${tools.length ? tools.map(([n, c]) => `${n} ${c}`).join(", ") : "none"}`);
  const commands = count(
    calls.filter((e) => e.payload["toolName"] === "bash"),
    (e) => (str(input(e)["command"]) === null ? null : oneLine(str(input(e)["command"]) as string)),
  );
  if (commands.length) lines.push(`commands: ${commands.map(([n, c]) => `${c}x ${n}`).join("; ")}`);
  const executables = count(
    t.probes.filter((p) => p.fields["role"] === t.role && within(p.id) && (p.fields["event"] ?? "").startsWith("exec ")),
    (p) => /comm=(\S+)/.exec(p.fields["event"] ?? "")?.[1] ?? null,
  );
  if (executables.length) lines.push(`executables: ${executables.map(([n, c]) => `${n} ${c}`).join(", ")}`);
  const skills = count(
    calls.filter((e) => e.payload["toolName"] === "read"),
    (e) => /\/skills\/([^/]+)\/SKILL\.md$/.exec(str(input(e)["path"]) ?? "")?.[1] ?? null,
  );
  if (skills.length) lines.push(`skills: ${skills.map(([n]) => n).join(", ")}`);
  const refused = seen.filter((e) => e.name === "guard_refused");
  if (refused.length) {
    const what = refused.map((e) => `${str(e.payload["rule"]) ?? "?"}: ${str(e.payload["tool"]) ?? "?"} ${str(e.payload["path"]) ?? str(e.payload["status"]) ?? ""}`.trim());
    lines.push(`guard refused: ${refused.length} (${what.join("; ")})`);
  }
  return lines.join("\n");
}
