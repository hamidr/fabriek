// One relay line per bus entry (ADR-039 point 2). The fields are relayed as
// the bus holds them, strings all, so the client and not the relay decides
// what a message means; the relay's only job is to say which stream and
// which entry.
import type { Entry } from "../bus/client.js";

export interface Line {
  stream: string;
  id: string;
  fields: Record<string, string>;
}

export function encodeLine(stream: string, entry: Entry): string {
  return JSON.stringify({ stream, id: entry.id, fields: entry.fields });
}

export function parseLine(line: string): Line {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    throw new Error("not a relay line: not JSON");
  }
  if (typeof raw !== "object" || raw === null) throw new Error("not a relay line: not an object");
  const o = raw as Record<string, unknown>;
  if (typeof o["stream"] !== "string") throw new Error("not a relay line: no stream");
  if (typeof o["id"] !== "string") throw new Error("not a relay line: no id");
  if (typeof o["fields"] !== "object" || o["fields"] === null) throw new Error("not a relay line: no fields");
  const fields: Record<string, string> = {};
  for (const [k, v] of Object.entries(o["fields"] as Record<string, unknown>)) fields[k] = String(v);
  return { stream: o["stream"], id: o["id"], fields };
}

/** Everything the operator may watch: every actor's four streams, the decider's mailbox, and the machine's. */
export function streamsFor(roles: string[]): string[] {
  const out: string[] = [];
  for (const r of [...roles, "decider"]) out.push(`control:${r}`, `mailbox:${r}`, `events:${r}`, `findings:${r}`);
  out.push("commands", "operator", "events:executor", "probes");
  return out;
}
