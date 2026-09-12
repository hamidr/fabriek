// A client of the bus (ADR-033): one connection, one user, the stream verbs.
// Calls are answered in order, which is what RESP promises on one socket, so
// a queue of pending promises is the whole of the bookkeeping.
import { createConnection, type Socket } from "node:net";
import { Decoder, encode, type Reply } from "./resp.js";

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

interface Pending {
  resolve(reply: Reply): void;
  reject(error: Error): void;
}

export class BusClient {
  private readonly pending: Pending[] = [];
  private readonly decoder = new Decoder();
  closed = false;

  private constructor(
    private readonly socket: Socket,
    private readonly user: string,
  ) {
    socket.on("data", (chunk) => {
      for (const reply of this.decoder.feed(chunk)) {
        const p = this.pending.shift();
        if (!p) continue;
        if (reply instanceof Error) p.reject(reply);
        else p.resolve(reply);
      }
    });
    const fail = (why: string) => {
      this.closed = true;
      for (const p of this.pending.splice(0)) p.reject(new Error(`bus closed: ${why}`));
    };
    socket.on("close", () => fail("connection closed"));
    socket.on("error", (e) => fail(e.message));
  }

  /** Connect and authenticate. The password lives in the AUTH command and nowhere on this object. */
  static async connect(options: BusOptions): Promise<BusClient> {
    const socket = createConnection({ host: options.host, port: options.port });
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });
    const client = new BusClient(socket, options.user);
    await client.call(["AUTH", options.user, options.password]);
    return client;
  }

  toString(): string {
    return `BusClient(${this.user})`;
  }

  private call(words: string[]): Promise<Reply> {
    if (this.closed) return Promise.reject(new Error("bus closed"));
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject });
      this.socket.write(encode(words));
    });
  }

  async ping(): Promise<void> {
    await this.call(["PING"]);
  }

  /** Append one entry, keeping the stream at about maxlen entries. */
  async xadd(stream: string, fields: Record<string, string>, maxlen: number): Promise<string> {
    const words = ["XADD", stream, "MAXLEN", "~", String(maxlen), "*"];
    for (const [k, v] of Object.entries(fields)) words.push(k, v);
    return String(await this.call(words));
  }

  /** Entries after id on one stream, waiting up to block milliseconds for one. */
  async xread(stream: string, after: string, block: number): Promise<Entry[]> {
    const reply = await this.call(["XREAD", "BLOCK", String(block), "STREAMS", stream, after]);
    return entriesOf(reply, stream);
  }

  /** Entries in a range, oldest first. */
  async xrange(stream: string, from = "-", to = "+", count?: number): Promise<Entry[]> {
    const words = ["XRANGE", stream, from, to];
    if (count !== undefined) words.push("COUNT", String(count));
    return rawEntries(await this.call(words));
  }

  close(): void {
    this.closed = true;
    this.socket.destroy();
  }
}

function rawEntries(reply: Reply): Entry[] {
  if (!Array.isArray(reply)) return [];
  return reply.map((e) => {
    const [id, flat] = e as [string, string[]];
    const fields: Record<string, string> = {};
    for (let i = 0; i + 1 < flat.length; i += 2) fields[String(flat[i])] = String(flat[i + 1]);
    return { id: String(id), fields };
  });
}

function entriesOf(reply: Reply, stream: string): Entry[] {
  if (!Array.isArray(reply)) return [];
  for (const s of reply) {
    const [name, entries] = s as [string, Reply];
    if (name === stream) return rawEntries(entries);
  }
  return [];
}
