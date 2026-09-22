// The bus as every actor reaches it (ADR-033, ADR-069): publish, read,
// range and the newest id, over NATS with JetStream. Driven against a small
// server standing in for nats-server, which answers the JetStream API this
// client asks and delivers a pull as the server does, with the sequence on
// the subject it asks acknowledgement on.
import { describe, it, after, before, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server, type Socket } from "node:net";
import { BusClient } from "./client.js";

interface Stored {
  subject: string;
  payload: string;
}

interface FakeConsumer {
  stream: string;
  next: number;
  filter: string | null;
}

const CRLF = "\r\n";
const CREATED = "2026-09-22T08:00:00.000Z";
const CREATED_MS = Date.parse(CREATED);

let server: Server;
let port = 0;
let streams: Map<string, Stored[]>;
let consumers: Map<string, FakeConsumer>;
let seen: string[];
let refuse: string[];
let connected: { user: string; pass: string } | null;

function line(socket: Socket, text: string): void {
  socket.write(text + CRLF);
}

function deliver(socket: Socket, inbox: string, payload: string, reply?: string): void {
  // MSG <subject> <sid> [reply-to] <bytes>, which is the order a reader of
  // a pull goes by: the sequence it was given is on the reply subject.
  const head = reply ? `${inbox} 1 ${reply}` : `${inbox} 1`;
  socket.write(`MSG ${head} ${Buffer.byteLength(payload)}${CRLF}${payload}${CRLF}`);
}

function status(socket: Socket, inbox: string, code: number, why: string): void {
  const head = `NATS/1.0 ${code} ${why}${CRLF}${CRLF}`;
  socket.write(`HMSG ${inbox} 1 ${head.length} ${head.length}${CRLF}${head}${CRLF}`);
}

/** The JetStream API and the subjects a stream captures, as much as this client asks of them. */
function answer(socket: Socket, subject: string, reply: string | null, payload: string): void {
  seen.push(subject);
  if (refuse.includes(subject)) {
    line(socket, `-ERR 'Permissions Violation for Publish to "${subject}"'`);
    return;
  }
  if (!reply) return;
  if (subject.startsWith("$JS.API.STREAM.CREATE.")) {
    const name = subject.slice("$JS.API.STREAM.CREATE.".length);
    if (streams.has(name)) {
      deliver(socket, reply, JSON.stringify({ error: { err_code: 10058, description: "stream name already in use" } }));
      return;
    }
    streams.set(name, []);
    deliver(socket, reply, JSON.stringify({ config: { name }, created: CREATED }));
    return;
  }
  if (subject.startsWith("$JS.API.STREAM.INFO.")) {
    const name = subject.slice("$JS.API.STREAM.INFO.".length);
    const held = streams.get(name);
    if (!held) {
      deliver(socket, reply, JSON.stringify({ error: { err_code: 10059, description: "stream not found" } }));
      return;
    }
    deliver(socket, reply, JSON.stringify({ created: CREATED, state: { last_seq: held.length, messages: held.length } }));
    return;
  }
  if (subject.startsWith("$JS.API.CONSUMER.CREATE.")) {
    const [stream, name] = subject.slice("$JS.API.CONSUMER.CREATE.".length).split(".");
    const held = streams.get(String(stream)) ?? [];
    const config = (JSON.parse(payload) as { config: Record<string, unknown> }).config;
    const policy = String(config["deliver_policy"]);
    const from = policy === "new" ? held.length : policy === "by_start_sequence" ? Number(config["opt_start_seq"]) - 1 : 0;
    consumers.set(`${stream}.${name}`, {
      stream: String(stream),
      next: from,
      filter: config["filter_subject"] ? String(config["filter_subject"]) : null,
    });
    deliver(socket, reply, JSON.stringify({ name }));
    return;
  }
  if (subject.startsWith("$JS.API.CONSUMER.MSG.NEXT.")) {
    const key = subject.slice("$JS.API.CONSUMER.MSG.NEXT.".length);
    const consumer = consumers.get(key);
    if (!consumer) {
      status(socket, reply, 404, "Consumer Deleted");
      return;
    }
    const held = streams.get(consumer.stream) ?? [];
    const batch = Number((JSON.parse(payload) as { batch?: number }).batch ?? 1);
    let sent = 0;
    while (consumer.next < held.length && sent < batch) {
      const sequence = consumer.next + 1;
      const entry = held[consumer.next];
      consumer.next += 1;
      if (!entry) continue;
      if (consumer.filter && entry.subject !== consumer.filter) continue;
      const ack = `$JS.ACK.${consumer.stream}.${key.split(".")[1]}.1.${sequence}.${sequence}.0.0`;
      deliver(socket, reply, entry.payload, ack);
      sent += 1;
    }
    status(socket, reply, 408, "Request Timeout");
    return;
  }
  // A subject a stream captures: the entry is kept and the sequence answered.
  for (const [name, held] of streams) {
    const captured = name === "findings" ? subject.startsWith("findings.") : name === subject.replace(/\./g, "-") || name === subject;
    if (!captured) continue;
    held.push({ subject, payload });
    deliver(socket, reply, JSON.stringify({ stream: name, seq: held.length }));
    return;
  }
  deliver(socket, reply, JSON.stringify({ error: { err_code: 10060, description: "no stream on subject" } }));
}

before(async () => {
  server = createServer((socket) => {
    line(socket, 'INFO {"server_id":"fake","max_payload":1048576,"headers":true}');
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk.toString("binary");
      for (;;) {
        const end = buffer.indexOf(CRLF);
        if (end < 0) return;
        const head = buffer.slice(0, end);
        const verb = head.split(" ")[0];
        if (verb === "PUB") {
          const parts = head.split(/\s+/);
          const bytes = Number(parts[parts.length - 1]);
          if (buffer.length < end + 2 + bytes + 2) return;
          const payload = buffer.slice(end + 2, end + 2 + bytes);
          buffer = buffer.slice(end + 2 + bytes + 2);
          answer(socket, String(parts[1]), parts.length === 4 ? String(parts[2]) : null, payload);
          continue;
        }
        buffer = buffer.slice(end + 2);
        if (verb === "PING") line(socket, "PONG");
        if (verb === "CONNECT") {
          const json = JSON.parse(head.slice("CONNECT ".length)) as { user: string; pass: string };
          connected = { user: json.user, pass: json.pass };
        }
      }
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const a = server.address();
  port = typeof a === "object" && a ? a.port : 0;
});

after(() => new Promise<void>((r) => server.close(() => r())));

beforeEach(() => {
  streams = new Map();
  consumers = new Map();
  seen = [];
  refuse = [];
  connected = null;
});

async function client(user = "acme-dev"): Promise<BusClient> {
  return BusClient.connect({ host: "127.0.0.1", port, user, password: "secret" });
}

describe("a bus client", () => {
  it("connects as its user and answers the server's PING, so a connection is not dropped", async () => {
    const c = await client();
    assert.deepEqual(connected, { user: "acme-dev", pass: "secret" });
    await c.ping();
    c.close();
  });

  it("makes a stream once, and finds a second connect's attempt already made", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("mailbox-dev", ["mailbox.dev"], 1000);
    await c.ensureStream("mailbox-dev", ["mailbox.dev"], 1000);
    assert.equal(streams.has("mailbox-dev"), true);
    c.close();
  });

  it("publishes an entry on the stream's subject and answers the id it was given", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("mailbox-dev", ["mailbox.dev"], 1000);
    const id = await c.xadd("mailbox:dev", { kind: "assignment", issue: "7" }, 1000);
    assert.equal(id, `${CREATED_MS}-1`);
    assert.deepEqual(streams.get("mailbox-dev")?.[0]?.subject, "mailbox.dev");
    c.close();
  });

  it("reads entries after an id, with their fields as they were written", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("mailbox-dev", ["mailbox.dev"], 1000);
    const first = await c.xadd("mailbox:dev", { kind: "one" }, 1000);
    await c.xadd("mailbox:dev", { kind: "two" }, 1000);
    const entries = await c.xread("mailbox:dev", first, 10);
    assert.deepEqual(
      entries.map((e) => e.fields["kind"]),
      ["two"],
    );
    assert.equal(entries[0]?.id, `${CREATED_MS}-2`);
    c.close();
  });

  it("reads from the tail when asked for what happens next, and misses what was there before", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("operator", ["operator"], 1000);
    await c.xadd("operator", { kind: "old" }, 1000);
    const entries = await c.xread("operator", "$", 10);
    assert.deepEqual(entries, []);
    c.close();
  });

  it("reads a stream from its start when the id it holds is from a stream that is gone", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("operator", ["operator"], 1000);
    await c.xadd("operator", { kind: "kept" }, 1000);
    // An id whose creation time is another stream's: what it names was
    // never in this one (ADR-069 point 7).
    const entries = await c.xread("operator", "1-1", 10);
    assert.deepEqual(
      entries.map((e) => e.fields["kind"]),
      ["kept"],
    );
    c.close();
  });

  it("goes on where it left off, without making a consumer for every read", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("commands", ["commands"], 1000);
    await c.xadd("commands", { kind: "one" }, 1000);
    const first = await c.xread("commands", "0-0", 10);
    const made = consumers.size;
    await c.xadd("commands", { kind: "two" }, 1000);
    const second = await c.xread("commands", first[0]?.id ?? "0-0", 10);
    assert.equal(second[0]?.fields["kind"], "two");
    assert.equal(consumers.size, made);
    c.close();
  });

  it("reads several streams at once, and names only those that had something", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("commands", ["commands"], 1000);
    await c.ensureStream("operator", ["operator"], 1000);
    await c.xadd("commands", { kind: "assign" }, 1000);
    const batches = await c.xreadMany({ commands: "0-0", operator: "0-0" }, 10);
    assert.deepEqual(Object.keys(batches), ["commands"]);
    assert.equal(batches["commands"]?.[0]?.fields["kind"], "assign");
    c.close();
  });

  it("reads every role's findings from one stream, filtered to the role asked for", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("findings", ["findings.*"], 1000);
    await c.xadd("findings:dev", { text: "dev's" }, 1000);
    await c.xadd("findings:reviewer", { text: "reviewer's" }, 1000);
    const entries = await c.xread("findings:dev", "0-0", 10);
    assert.deepEqual(
      entries.map((e) => e.fields["text"]),
      ["dev's"],
    );
    c.close();
  });

  it("answers the newest id, and 0-0 for a stream nothing has been written to", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("operator", ["operator"], 1000);
    assert.equal(await c.lastId("operator"), "0-0");
    await c.xadd("operator", { kind: "one" }, 1000);
    assert.equal(await c.lastId("operator"), `${CREATED_MS}-1`);
    c.close();
  });

  it("reads a range, oldest first, and stops at the id it was asked to stop at", async () => {
    const c = await client("acme-executor");
    await c.ensureStream("events-dev", ["events.dev"], 1000);
    const first = await c.xadd("events:dev", { name: "one" }, 1000);
    const second = await c.xadd("events:dev", { name: "two" }, 1000);
    await c.xadd("events:dev", { name: "three" }, 1000);
    const entries = await c.xrange("events:dev", first, second);
    assert.deepEqual(
      entries.map((e) => e.fields["name"]),
      ["one", "two"],
    );
    c.close();
  });

  it("when the bus refuses a subject, the call rejects in the server's own words", async () => {
    const c = await client("acme-dev");
    await c.ensureStream("control-tester", ["control.tester"], 1000);
    refuse = ["control.tester"];
    await assert.rejects(c.xadd("control:tester", { kind: "ready" }, 1000), /Permissions Violation/);
    c.close();
  });

  it("when the connection goes, what is waiting is told and the client says it is closed", async () => {
    const c = await client();
    const waiting = c.lastId("operator");
    c.close();
    await assert.rejects(waiting, /bus closed|did not answer/);
    assert.equal(c.closed, true);
  });
});
