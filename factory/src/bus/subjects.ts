// What a stream was called on Valkey and what it is on NATS (ADR-069 point
// 5). The rest of the package goes on naming `mailbox:dev`, and here that
// becomes the subject it is published on, the stream it lives in, and the
// filter a reader of it pulls with.
//
// A stream per role, because a pull permission is bounded by the stream's
// name and a shared stream would let a role pull from a peer's consumer.
// Findings are the one stream every role reads, so they share it and a
// reader filters by subject.

export interface Placed {
  /** Where an entry is published. */
  subject: string;
  /** The stream that holds it. */
  stream: string;
  /** What a reader of this name pulls with, when the stream holds more than it. */
  filter: string | null;
}

export function place(name: string): Placed {
  const at = name.indexOf(":");
  if (at < 0) return { subject: name, stream: name, filter: null };
  const kind = name.slice(0, at);
  const who = name.slice(at + 1);
  const subject = `${kind}.${who}`;
  if (kind === "findings") return { subject, stream: "findings", filter: subject };
  return { subject, stream: `${kind}-${who}`, filter: null };
}

/** Every stream one factory's account holds, and the subjects each captures. */
export function streamsOf(roles: string[]): { name: string; subjects: string[] }[] {
  const out: { name: string; subjects: string[] }[] = [];
  for (const role of roles) {
    out.push({ name: `mailbox-${role}`, subjects: [`mailbox.${role}`] });
    out.push({ name: `control-${role}`, subjects: [`control.${role}`] });
    out.push({ name: `events-${role}`, subjects: [`events.${role}`] });
  }
  out.push({ name: "findings", subjects: ["findings.*"] });
  out.push({ name: "commands", subjects: ["commands"] });
  out.push({ name: "operator", subjects: ["operator"] });
  out.push({ name: "probes", subjects: ["probes"] });
  return out;
}

/**
 * The stream sequence a delivered message carries, read off the subject
 * JetStream asks acknowledgement on. It has two shapes, with and without
 * the domain and the account before the stream, and in both the sequence
 * is the second token after the consumer's name.
 */
export function sequenceOf(ackSubject: string | null): number | null {
  if (!ackSubject) return null;
  const t = ackSubject.split(".");
  if (t.length === 9) return Number(t[5]);
  if (t.length === 11) return Number(t[7]);
  return null;
}

/**
 * An entry's id: the stream's creation time and the entry's sequence
 * (ADR-069 point 7). Two ids from either side of a restart never compare
 * as neighbours, which a bare sequence starting again at 1 would.
 */
export function idOf(createdMs: number, sequence: number): string {
  return `${createdMs}-${sequence}`;
}

export function readId(id: string): { created: number; sequence: number } | null {
  const [a, b] = id.split("-");
  if (a === undefined || b === undefined) return null;
  const created = Number(a);
  const sequence = Number(b);
  if (!Number.isFinite(created) || !Number.isFinite(sequence)) return null;
  return { created, sequence };
}
