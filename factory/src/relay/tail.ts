// The relay's loop (ADR-039 point 2): read every stream from where it was
// last read, print each entry, and when the bus goes away, wait, connect
// again and read on from the same ids. A bus with no persistence comes back
// empty and hands out ids later than any it gave before, so reading on from
// the last id printed repeats nothing and skips nothing it still holds.
import type { Entry } from "../bus/client.js";
import { encodeLine } from "./format.js";

/** What the loop needs of a connection: the one read verb, and whether it is still open. */
export interface Tailed {
  closed: boolean;
  xreadMany(after: Record<string, string>, block: number): Promise<Record<string, Entry[]>>;
  close(): void;
}

export interface TailOptions {
  streams: string[];
  /** The id every stream is first read after: "$" for what happens next, "0-0" for what is held. */
  from: string;
  connect(): Promise<Tailed>;
  write(line: string): void;
  /** The pause before connecting again. */
  retry(): Promise<void>;
  /** How long one read waits for an entry, in milliseconds. */
  block?: number;
  /** Asked after every read; true ends the loop. For tests: the relay itself never ends. */
  until?(): boolean;
}

export async function tail(o: TailOptions): Promise<void> {
  const after: Record<string, string> = {};
  for (const s of o.streams) after[s] = o.from;
  let client: Tailed | undefined;
  for (;;) {
    try {
      if (!client || client.closed) client = await o.connect();
      const batches = await client.xreadMany(after, o.block ?? 5000);
      for (const [stream, entries] of Object.entries(batches)) {
        for (const e of entries) {
          after[stream] = e.id;
          o.write(encodeLine(stream, e));
        }
      }
    } catch {
      if (client && !client.closed) client.close();
      client = undefined;
      await o.retry();
    }
    if (o.until?.()) return;
  }
}
