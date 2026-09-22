// The NATS client protocol, as much of it as the bus needs (ADR-069 point
// 6): the text protocol is line-based with a payload after the line, so a
// decoder is a small state machine over the bytes as they arrive.
//
// What the server sends: INFO, PING, PONG, +OK, -ERR, MSG and HMSG. What we
// send is written by the client on top of this.

export interface Info {
  kind: "INFO";
  json: Record<string, unknown>;
}

export interface Message {
  kind: "MSG";
  subject: string;
  sid: string;
  reply: string | null;
  /** The status a JetStream API or pull reply carries in its header, when it has one. */
  status: number | null;
  description: string | null;
  headers: Record<string, string>;
  payload: string;
}

export interface Control {
  kind: "PING" | "PONG" | "OK";
}

export interface ServerError {
  kind: "ERR";
  message: string;
}

export type Frame = Info | Message | Control | ServerError;

const CRLF = "\r\n";

/** Feed bytes, take whole frames. What is left over waits for the next chunk. */
export class Decoder {
  private buffer = "";

  feed(chunk: Buffer | string): Frame[] {
    this.buffer += typeof chunk === "string" ? chunk : chunk.toString("binary");
    const out: Frame[] = [];
    for (;;) {
      const frame = this.next();
      if (frame === null) return out;
      out.push(frame);
    }
  }

  private next(): Frame | null {
    const end = this.buffer.indexOf(CRLF);
    if (end < 0) return null;
    const line = this.buffer.slice(0, end);
    const verb = line.split(" ", 1)[0]?.toUpperCase() ?? "";
    switch (verb) {
      case "PING":
      case "PONG":
        this.buffer = this.buffer.slice(end + 2);
        return { kind: verb };
      case "+OK":
        this.buffer = this.buffer.slice(end + 2);
        return { kind: "OK" };
      case "-ERR":
        this.buffer = this.buffer.slice(end + 2);
        return { kind: "ERR", message: line.slice(4).trim().replace(/^'|'$/g, "") };
      case "INFO":
        this.buffer = this.buffer.slice(end + 2);
        return { kind: "INFO", json: parseJson(line.slice(4)) };
      case "MSG":
      case "HMSG":
        return this.message(line, end, verb === "HMSG");
      default:
        // A line this client does not know is dropped rather than read as a
        // payload's worth of bytes, which would put the stream out of step.
        this.buffer = this.buffer.slice(end + 2);
        return this.next();
    }
  }

  private message(line: string, end: number, hasHeaders: boolean): Frame | null {
    const parts = line.split(/\s+/).slice(1);
    const sizes = hasHeaders ? 2 : 1;
    // subject, sid and the sizes, with a reply subject between them or not.
    if (parts.length < 2 + sizes) {
      this.buffer = this.buffer.slice(end + 2);
      return this.next();
    }
    const total = Number(parts[parts.length - 1]);
    const headerBytes = hasHeaders ? Number(parts[parts.length - 2]) : 0;
    const reply = parts.length === 3 + sizes ? (parts[2] ?? null) : null;
    const start = end + 2;
    if (this.buffer.length < start + total + 2) return null;
    const body = this.buffer.slice(start, start + total);
    this.buffer = this.buffer.slice(start + total + 2);
    const raw = body.slice(0, headerBytes);
    const payload = body.slice(headerBytes);
    const { status, description, headers } = parseHeaders(raw);
    return {
      kind: "MSG",
      subject: parts[0] ?? "",
      sid: parts[1] ?? "",
      reply,
      status,
      description,
      headers,
      payload,
    };
  }
}

/**
 * A header block: its first line is the protocol's version and, on a status
 * message, the code and its description. A pull that times out or finds
 * nothing is such a message and carries no payload at all, so the code is
 * what a reader goes by.
 */
function parseHeaders(raw: string): Pick<Message, "status" | "description" | "headers"> {
  const headers: Record<string, string> = {};
  if (raw === "") return { status: null, description: null, headers };
  const lines = raw.split(CRLF).filter((l) => l !== "");
  const first = lines.shift() ?? "";
  const match = /^NATS\/1\.0(?:\s+(\d{3}))?(?:\s+(.*))?$/.exec(first);
  for (const line of lines) {
    const at = line.indexOf(":");
    if (at > 0) headers[line.slice(0, at).trim()] = line.slice(at + 1).trim();
  }
  return {
    status: match?.[1] ? Number(match[1]) : null,
    description: match?.[2]?.trim() || null,
    headers,
  };
}

function parseJson(text: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(text);
    return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** CONNECT, with the user's own inbox prefix: a user may subscribe to no other's (ADR-069 point 4). */
export function connectLine(o: { user: string; password: string }): string {
  const json = JSON.stringify({
    verbose: false,
    pedantic: false,
    tls_required: false,
    user: o.user,
    pass: o.password,
    name: `fabriek-${o.user}`,
    lang: "node",
    version: "1.0.0",
    protocol: 1,
    headers: true,
    no_responders: false,
  });
  return `CONNECT ${json}${CRLF}`;
}

export function pubLine(subject: string, payload: string, reply?: string): string {
  const bytes = Buffer.byteLength(payload);
  const to = reply ? `${subject} ${reply}` : subject;
  return `PUB ${to} ${bytes}${CRLF}${payload}${CRLF}`;
}

export function subLine(subject: string, sid: string): string {
  return `SUB ${subject} ${sid}${CRLF}`;
}

export function unsubLine(sid: string): string {
  return `UNSUB ${sid}${CRLF}`;
}
