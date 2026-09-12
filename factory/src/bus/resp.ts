// RESP2, as much of it as an actor needs: encode a command as an array of
// bulk strings, and decode simple strings, errors, integers, bulk strings and
// arrays, nil included, across packet boundaries. No pipelining tricks and no
// RESP3: what is spoken here is XADD, XREAD, XRANGE, AUTH and PING.

export type Reply = string | number | null | Error | Reply[];

const CRLF = "\r\n";

/** A command as Valkey reads it: every word a bulk string. */
export function encode(words: readonly string[]): string {
  let out = `*${words.length}${CRLF}`;
  for (const w of words) out += `$${Buffer.byteLength(w)}${CRLF}${w}${CRLF}`;
  return out;
}

/** Incremental decoder: feed bytes, get the replies that are complete. */
export class Decoder {
  private buffer: Buffer = Buffer.alloc(0);

  feed(chunk: Buffer): Reply[] {
    this.buffer = this.buffer.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.buffer, chunk]);
    const out: Reply[] = [];
    for (;;) {
      const parsed = this.parse(0);
      if (parsed === undefined) return out;
      out.push(parsed.value);
      this.buffer = this.buffer.subarray(parsed.end);
    }
  }

  /** One reply starting at offset, or undefined when the bytes stop short. */
  private parse(at: number): { value: Reply; end: number } | undefined {
    const b = this.buffer;
    if (at >= b.length) return undefined;
    const lineEnd = b.indexOf(CRLF, at + 1);
    if (lineEnd < 0) return undefined;
    const line = b.toString("utf8", at + 1, lineEnd);
    const next = lineEnd + 2;
    switch (String.fromCharCode(b[at] ?? 0)) {
      case "+":
        return { value: line, end: next };
      case "-":
        return { value: new Error(line), end: next };
      case ":":
        return { value: Number(line), end: next };
      case "$": {
        const n = Number(line);
        if (n < 0) return { value: null, end: next };
        if (b.length < next + n + 2) return undefined;
        return { value: b.toString("utf8", next, next + n), end: next + n + 2 };
      }
      case "*": {
        const n = Number(line);
        if (n < 0) return { value: null, end: next };
        const items: Reply[] = [];
        let cursor = next;
        for (let i = 0; i < n; i++) {
          const item = this.parse(cursor);
          if (item === undefined) return undefined;
          items.push(item.value);
          cursor = item.end;
        }
        return { value: items, end: cursor };
      }
      default:
        throw new Error(`not RESP: ${String.fromCharCode(b[at] ?? 0)}`);
    }
  }
}
