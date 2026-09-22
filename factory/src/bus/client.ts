// A client of the bus (ADR-033, ADR-069): one connection, one user, the
// stream verbs the rest of the package speaks. The bus is a NATS account
// with JetStream memory streams, so a verb here is one request and its
// reply on the user's own inbox, and a read is a pull on a consumer of its
// own.
//
// The interface above this file has not moved: the six verbs, and a stream
// sequence where Valkey's id was.
import { createConnection, type Socket } from "node:net";
import { Decoder, connectLine, pubLine, subLine, unsubLine, type Frame, type Message } from "./proto.js";
import { place, sequenceOf, idOf, readId } from "./subjects.js";

export interface BusOptions {
  host: string;
  port: number;
  user: string;
  password: string;
}

export interface Entry {
  id: string;
  fields: Record<string, string>;
}

interface Waiting {
  /** Every message on this inbox, until the caller says it has what it wants. */
  take(message: Message): boolean;
  fail(error: Error): void;
}

/** How long a consumer with nobody pulling on it is kept, in nanoseconds. */
const CONSUMER_IDLE_NS = 300_000_000_000;
/** What one pull may bring back at once. */
const BATCH = 128;
/** How long a request that is not a pull waits for its answer. */
const REQUEST_MS = 5000;

interface Reader {
  consumer: string;
  /** The id this reader last handed out, so the next call may go on where it left off. */
  at: string;
}

export class BusClient {
  /**
   * Who is waiting for what, by subscription id. A pull's messages arrive
   * under their own subject and not the inbox they were asked on, so the
   * subscription is what tells one caller's answers from another's: a
   * subscription per request, ended with it.
   */
  private readonly waiting = new Map<string, Waiting>();
  private readonly decoder = new Decoder();
  private readonly created = new Map<string, number>();
  private readonly readers = new Map<string, Reader>();
  private counter = 0;
  closed = false;

  private constructor(
    private readonly socket: Socket,
    private readonly user: string,
  ) {
    socket.on("data", (chunk) => {
      for (const frame of this.decoder.feed(chunk)) this.frame(frame);
    });
    const fail = (why: string) => {
      this.closed = true;
      for (const [sid, w] of this.waiting) {
        this.waiting.delete(sid);
        w.fail(new Error(`bus closed: ${why}`));
      }
    };
    socket.on("close", () => fail("connection closed"));
    socket.on("error", (e) => fail(e.message));
  }

  private frame(frame: Frame): void {
    switch (frame.kind) {
      case "PING":
        this.socket.write("PONG\r\n");
        return;
      case "MSG": {
        const w = this.waiting.get(frame.sid);
        if (w && w.take(frame)) this.end(frame.sid);
        return;
      }
      case "ERR": {
        // A permissions violation names the subject it was for, and every
        // caller waiting is owed it: the server does not say whose it was.
        const error = new Error(frame.message);
        for (const [sid, w] of this.waiting) {
          this.waiting.delete(sid);
          w.fail(error);
        }
        return;
      }
      default:
        return;
    }
  }

  /**
   * Connect and authenticate. The password travels in CONNECT and is held
   * nowhere on this object. The inbox is the user's own, which is the only
   * one its subscribe permission allows (ADR-069 point 4).
   */
  static async connect(options: BusOptions): Promise<BusClient> {
    const socket = createConnection({ host: options.host, port: options.port });
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });
    const client = new BusClient(socket, options.user);
    await client.greeted();
    socket.write(connectLine(options));
    await client.roundTrip();
    return client;
  }

  /** The server speaks first; nothing is sent before its INFO has been read. */
  private greeted(): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the bus said nothing")), REQUEST_MS);
      const onData = () => {
        clearTimeout(timer);
        this.socket.off("data", onData);
        resolve();
      };
      this.socket.prependListener("data", onData);
    });
  }

  /** PING and its PONG: the answer that says CONNECT was accepted. */
  private roundTrip(): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the bus did not answer PING")), REQUEST_MS);
      const onData = (chunk: Buffer) => {
        const text = chunk.toString("binary");
        if (text.includes("PONG")) {
          clearTimeout(timer);
          this.socket.off("data", onData);
          resolve();
        } else if (text.startsWith("-ERR")) {
          clearTimeout(timer);
          this.socket.off("data", onData);
          reject(new Error(text.trim()));
        }
      };
      this.socket.prependListener("data", onData);
      this.socket.write("PING\r\n");
    });
  }

  /** An inbox of this user's own, and the subscription that hears it. */
  private listen(w: Waiting): { inbox: string; sid: string } {
    this.counter += 1;
    const sid = String(this.counter);
    const inbox = `_INBOX.${this.user}.${sid}`;
    this.waiting.set(sid, w);
    this.socket.write(subLine(inbox, sid));
    return { inbox, sid };
  }

  /** The subscription goes with the answer it was made for. */
  private end(sid: string): void {
    this.waiting.delete(sid);
    if (!this.closed) this.socket.write(unsubLine(sid));
  }

  /** One request, one reply. */
  private request(subject: string, payload: string, timeout = REQUEST_MS): Promise<Message> {
    return new Promise((resolve, reject) => {
      if (this.closed) {
        reject(new Error("bus closed"));
        return;
      }
      let sid = "";
      const timer = setTimeout(() => {
        this.end(sid);
        reject(new Error(`the bus did not answer ${subject}`));
      }, timeout);
      const listening = this.listen({
        take(message) {
          clearTimeout(timer);
          resolve(message);
          return true;
        },
        fail(error) {
          clearTimeout(timer);
          reject(error);
        },
      });
      sid = listening.sid;
      this.socket.write(pubLine(subject, payload, listening.inbox));
    });
  }

  /**
   * One pull: several messages on one inbox, ended by a status message when
   * the batch runs out or the wait does. Nothing is acknowledged, because a
   * reader keeps its own position (ADR-069 point 4).
   */
  private pull(stream: string, consumer: string, batch: number, waitMs: number): Promise<Message[]> {
    return new Promise((resolve, reject) => {
      if (this.closed) {
        reject(new Error("bus closed"));
        return;
      }
      const out: Message[] = [];
      let sid = "";
      const timer = setTimeout(() => {
        this.end(sid);
        resolve(out);
      }, waitMs + REQUEST_MS);
      const done = () => {
        clearTimeout(timer);
        resolve(out);
        return true;
      };
      const listening = this.listen({
        take(message) {
          // A status message ends the pull: the batch ran out, or the wait
          // did, and the messages before it are what there was.
          if (message.status !== null) return done();
          out.push(message);
          return out.length >= batch ? done() : false;
        },
        fail(error) {
          clearTimeout(timer);
          reject(error);
        },
      });
      sid = listening.sid;
      const body = JSON.stringify({ batch, expires: waitMs * 1_000_000, no_wait: waitMs === 0 });
      this.socket.write(pubLine(`$JS.API.CONSUMER.MSG.NEXT.${stream}.${consumer}`, body, listening.inbox));
    });
  }

  private async api(subject: string, body: unknown): Promise<Record<string, unknown>> {
    const reply = await this.request(subject, JSON.stringify(body));
    const answer = parse(reply.payload);
    const error = answer["error"];
    if (error && typeof error === "object") {
      const e = error as { description?: string; err_code?: number };
      throw new BusApiError(e.description ?? `the bus refused ${subject}`, e.err_code ?? 0);
    }
    return answer;
  }

  toString(): string {
    return `BusClient(${this.user})`;
  }

  async ping(): Promise<void> {
    await this.roundTrip();
  }

  /**
   * A stream, made if it is absent and left as it is if it is there. The
   * executor's, at every connect and before it reconciles (ADR-069 point
   * 5); no other user may ask.
   */
  async ensureStream(name: string, subjects: string[], maxMsgs: number): Promise<void> {
    const config = {
      name,
      subjects,
      storage: "memory",
      retention: "limits",
      discard: "old",
      max_msgs: maxMsgs,
      num_replicas: 1,
    };
    try {
      await this.api(`$JS.API.STREAM.CREATE.${name}`, config);
    } catch (e) {
      // Already there with these subjects, which is what a second connect
      // finds; anything else is the caller's to hear.
      if (!(e instanceof BusApiError) || e.code !== 10058) throw e;
    }
    this.created.delete(name);
  }

  /** When the stream was made, in milliseconds, which is the first half of every id it gives out. */
  private async createdAt(stream: string): Promise<number> {
    const held = this.created.get(stream);
    if (held !== undefined) return held;
    const info = await this.api(`$JS.API.STREAM.INFO.${stream}`, {});
    const created = Date.parse(String(info["created"] ?? ""));
    const ms = Number.isFinite(created) ? created : 0;
    this.created.set(stream, ms);
    return ms;
  }

  /** Append one entry. The stream's bound is its own (ADR-069 point 5), so maxlen is the creator's business and not this call's. */
  async xadd(stream: string, fields: Record<string, string>, _maxlen: number): Promise<string> {
    const at = place(stream);
    const reply = await this.request(at.subject, JSON.stringify(fields));
    const ack = parse(reply.payload);
    const error = ack["error"];
    if (error && typeof error === "object") {
      const e = error as { description?: string; err_code?: number };
      throw new BusApiError(e.description ?? `the bus refused ${at.subject}`, e.err_code ?? 0);
    }
    const sequence = Number(ack["seq"] ?? 0);
    return idOf(await this.createdAt(at.stream), sequence);
  }

  /**
   * Entries after id on one stream, waiting up to block milliseconds for
   * one. A stream the executor has not made yet is no entries: a role that
   * connects first waits for it, as it waits for a bus that is away
   * (ADR-069 point 5).
   */
  async xread(stream: string, after: string, block: number): Promise<Entry[]> {
    const at = place(stream);
    try {
      const consumer = await this.readerFor(stream, after);
      const messages = await this.pull(at.stream, consumer, BATCH, block);
      return this.entries(stream, await this.createdAt(at.stream), messages);
    } catch (e) {
      if (absent(e)) return [];
      throw e;
    }
  }

  /** Entries after each stream's id, on several streams, waiting up to block milliseconds. */
  async xreadMany(after: Record<string, string>, block: number): Promise<Record<string, Entry[]>> {
    const names = Object.keys(after);
    if (names.length === 0) return {};
    const out: Record<string, Entry[]> = {};
    const reads = names.map(async (name) => {
      const entries = await this.xread(name, after[name] ?? "$", block);
      if (entries.length > 0) out[name] = entries;
    });
    await Promise.all(reads);
    return out;
  }

  /** Entries in a range, oldest first. */
  async xrange(stream: string, from = "-", to = "+", count?: number): Promise<Entry[]> {
    const at = place(stream);
    let entries: Entry[];
    try {
      const start = from === "-" ? { deliver_policy: "all" } : await this.startAt(at.stream, from, true);
      const consumer = await this.makeConsumer(at, start);
      entries = this.entries(stream, await this.createdAt(at.stream), await this.pull(at.stream, consumer, count ?? BATCH, 0));
    } catch (e) {
      if (absent(e)) return [];
      throw e;
    }
    if (to === "+") return entries;
    const end = readId(to);
    return end === null ? entries : entries.filter((e) => (readId(e.id)?.sequence ?? 0) <= end.sequence);
  }

  /** The newest entry's id, or 0-0 on an empty stream: where a reader starts so nothing written before its first read is missed. */
  async lastId(stream: string): Promise<string> {
    const at = place(stream);
    let info: Record<string, unknown>;
    try {
      info = await this.api(`$JS.API.STREAM.INFO.${at.stream}`, {});
    } catch (e) {
      if (absent(e)) return "0-0";
      throw e;
    }
    const state = (info["state"] ?? {}) as Record<string, unknown>;
    const last = Number(state["last_seq"] ?? 0);
    if (last === 0) return "0-0";
    return idOf(await this.createdAt(at.stream), last);
  }

  close(): void {
    this.closed = true;
    this.socket.destroy();
  }

  /**
   * The consumer a reader of this name pulls on. One is kept while the
   * caller goes on reading where it left off; a caller that names another
   * id has seeked, and gets a consumer that starts there.
   */
  private async readerFor(name: string, after: string): Promise<string> {
    const at = place(name);
    const key = `${at.stream}|${at.filter ?? ""}`;
    const held = this.readers.get(key);
    if (held && held.at === after) return held.consumer;
    const consumer = await this.makeConsumer(at, await this.startAt(at.stream, after, false));
    this.readers.set(key, { consumer, at: after });
    return consumer;
  }

  /**
   * Where a read starts. An id from a stream made before this one is an id
   * of a bus that has restarted, and what it names is gone, so the reader
   * takes the stream from its start rather than skipping what it never saw
   * (ADR-069 point 7).
   */
  private async startAt(stream: string, after: string, inclusive: boolean): Promise<Record<string, unknown>> {
    if (after === "$") return { deliver_policy: "new" };
    const id = readId(after);
    if (id === null) return { deliver_policy: "all" };
    if (id.created === 0 && id.sequence === 0) return { deliver_policy: "all" };
    if (id.created !== (await this.createdAt(stream))) return { deliver_policy: "all" };
    return { deliver_policy: "by_start_sequence", opt_start_seq: id.sequence + (inclusive ? 0 : 1) };
  }

  private async makeConsumer(at: ReturnType<typeof place>, start: Record<string, unknown>): Promise<string> {
    this.counter += 1;
    const name = `${this.user}-${process.pid}-${this.counter}`.replace(/[^A-Za-z0-9_-]/g, "-");
    const config: Record<string, unknown> = {
      name,
      ack_policy: "none",
      replay_policy: "instant",
      inactive_threshold: CONSUMER_IDLE_NS,
      ...start,
    };
    if (at.filter) config["filter_subject"] = at.filter;
    // The request carries the stream and the config, and the consumer's
    // name is in the config alone: the server refuses a name beside it.
    await this.api(`$JS.API.CONSUMER.CREATE.${at.stream}.${name}`, { stream_name: at.stream, config });
    return name;
  }

  private entries(name: string, created: number, messages: Message[]): Entry[] {
    const at = place(name);
    const out: Entry[] = [];
    for (const m of messages) {
      const sequence = sequenceOf(m.reply);
      if (sequence === null) continue;
      out.push({ id: idOf(created, sequence), fields: fieldsOf(m.payload) });
    }
    if (out.length > 0) {
      const key = `${at.stream}|${at.filter ?? ""}`;
      const reader = this.readers.get(key);
      const last = out[out.length - 1];
      if (reader && last) reader.at = last.id;
    }
    return out;
  }
}

/** What the bus refused, in its own words and with its own code. */
export class BusApiError extends Error {
  override name = "BusApiError";
  constructor(
    message: string,
    readonly code: number,
  ) {
    super(message);
  }
}

/** A stream or a consumer that is not there, which is a stream not made yet. */
function absent(e: unknown): boolean {
  return e instanceof BusApiError && (e.code === 10059 || e.code === 10014);
}

function parse(payload: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(payload);
    return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function fieldsOf(payload: string): Record<string, string> {
  const value = parse(payload);
  const fields: Record<string, string> = {};
  for (const [k, v] of Object.entries(value)) fields[k] = typeof v === "string" ? v : JSON.stringify(v);
  return fields;
}
