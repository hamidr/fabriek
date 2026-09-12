// What travels on the bus (ADR-033). A stream entry is flat string fields, so
// each message kind says which fields it has and how each reads; anything
// else on the entry is refused rather than dropped, and a message never
// carries the identity of its writer, because that is the stream's name and
// the ACL's to vouch for (ADR-033 point 3).
import { isName } from "./names.js";

export type Message =
  /** An actor is free, and this is what it can do (its role's capabilities). */
  | { kind: "ready"; capabilities: string[] }
  /** The executor points an actor at an issue; the actor reads the rest. */
  | { kind: "assignment"; issue: number; attempt: number }
  /** The actor took it; the executor moves assigning to assigned on this. */
  | { kind: "ack"; issue: number }
  /** The executor asks every live actor what it holds (ADR-033 point 4). */
  | { kind: "reconcile" }
  /** What an actor holds, answered at reconciliation; taken as a claim. */
  | { kind: "held"; issues: number[] }
  /** The operator speaks into a running turn, or ends it. */
  | { kind: "steer"; text: string }
  | { kind: "abort" }
  /** A turn or tool event the extension publishes for the operator to watch. */
  | { kind: "event"; name: string; payload: unknown }
  /** Something a role noticed, for every other role to read. */
  | { kind: "finding"; text: string };

export type Kind = Message["kind"];
export type Fields = Record<string, string>;

export class MessageError extends Error {
  override name = "MessageError";
}

const SHAPE: Record<Kind, readonly string[]> = {
  ready: ["capabilities"],
  assignment: ["issue", "attempt"],
  ack: ["issue"],
  reconcile: [],
  held: ["issues"],
  steer: ["text"],
  abort: [],
  event: ["name", "json"],
  finding: ["text"],
};

function refuse(message: string): never {
  throw new MessageError(message);
}

function integer(fields: Fields, key: string): number {
  const v = fields[key];
  if (v === undefined || !/^[1-9][0-9]*$/.test(v)) refuse(`${key} must be a positive integer`);
  return Number(v);
}

function list(fields: Fields, key: string): string[] {
  const v = fields[key];
  if (v === undefined) refuse(`${key} is required`);
  return v === "" ? [] : v.split(",");
}

/** One message out of a stream entry's fields, or a MessageError. */
export function parseMessage(fields: Fields): Message {
  const kind = fields["kind"];
  if (kind === undefined || !(kind in SHAPE)) refuse(`not a message kind: ${String(kind)}`);
  const k = kind as Kind;
  for (const key of Object.keys(fields)) {
    if (key !== "kind" && !SHAPE[k].includes(key)) refuse(`${k} does not carry ${key}`);
  }
  for (const key of SHAPE[k]) {
    if (!(key in fields)) refuse(`${k} needs ${key}`);
  }
  switch (k) {
    case "ready": {
      const capabilities = list(fields, "capabilities");
      for (const c of capabilities) if (!isName(c)) refuse(`not a capability name: ${c}`);
      return { kind: k, capabilities };
    }
    case "assignment":
      return { kind: k, issue: integer(fields, "issue"), attempt: integer(fields, "attempt") };
    case "ack":
      return { kind: k, issue: integer(fields, "issue") };
    case "reconcile":
      return { kind: k };
    case "held": {
      const issues = list(fields, "issues").map((s) => {
        if (!/^[1-9][0-9]*$/.test(s)) refuse(`issues must be issue numbers: ${s}`);
        return Number(s);
      });
      return { kind: k, issues };
    }
    case "steer":
      return { kind: k, text: fields["text"] ?? "" };
    case "abort":
      return { kind: k };
    case "event": {
      const name = fields["name"] ?? "";
      if (!/^[a-z_]+$/.test(name)) refuse("event name must be a lowercase identifier");
      let payload: unknown;
      try {
        payload = JSON.parse(fields["json"] ?? "");
      } catch {
        refuse("event json must be JSON");
      }
      return { kind: k, name, payload };
    }
    case "finding":
      return { kind: k, text: fields["text"] ?? "" };
  }
}

/** The fields a message is written to a stream as. parseMessage(toFields(m)) is m. */
export function toFields(m: Message): Fields {
  switch (m.kind) {
    case "ready":
      return { kind: m.kind, capabilities: m.capabilities.join(",") };
    case "assignment":
      return { kind: m.kind, issue: String(m.issue), attempt: String(m.attempt) };
    case "ack":
      return { kind: m.kind, issue: String(m.issue) };
    case "reconcile":
      return { kind: m.kind };
    case "held":
      return { kind: m.kind, issues: m.issues.join(",") };
    case "steer":
      return { kind: m.kind, text: m.text };
    case "abort":
      return { kind: m.kind };
    case "event":
      return { kind: m.kind, name: m.name, json: JSON.stringify(m.payload) };
    case "finding":
      return { kind: m.kind, text: m.text };
  }
}
