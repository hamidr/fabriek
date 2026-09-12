// The bus is spoken over a socket in RESP, Valkey's wire protocol, with no
// client library: the handful of stream verbs an actor needs is small enough
// to own, and a dependency here would be the only one in the package.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { encode, Decoder } from "./resp.js";

describe("RESP on the wire", () => {
  it("a command is an array of bulk strings", () => {
    assert.equal(encode(["PING"]), "*1\r\n$4\r\nPING\r\n");
    assert.equal(encode(["XADD", "s", "*", "k", "v"]), "*5\r\n$4\r\nXADD\r\n$1\r\ns\r\n$1\r\n*\r\n$1\r\nk\r\n$1\r\nv\r\n");
  });

  it("a bulk string carries bytes, so a value with a newline survives", () => {
    assert.equal(encode(["SET", "k", "a\r\nb"]), "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$4\r\na\r\nb\r\n");
  });

  it("simple strings, errors, integers, bulk and arrays are decoded, nil included", () => {
    const d = new Decoder();
    const out = d.feed(Buffer.from("+PONG\r\n-ERR no\r\n:7\r\n$3\r\nabc\r\n$-1\r\n*2\r\n$1\r\na\r\n:1\r\n*-1\r\n"));
    assert.deepEqual(out, ["PONG", new Error("ERR no"), 7, "abc", null, ["a", 1], null]);
  });

  it("a reply split across packets is assembled, and the rest waits", () => {
    const d = new Decoder();
    assert.deepEqual(d.feed(Buffer.from("$5\r\nhel")), []);
    assert.deepEqual(d.feed(Buffer.from("lo\r\n+OK\r\n:")), ["hello", "OK"]);
    assert.deepEqual(d.feed(Buffer.from("3\r\n")), [3]);
  });

  it("an XREAD reply is nested arrays of stream, entries, id and flat fields", () => {
    const d = new Decoder();
    const wire = "*1\r\n*2\r\n$9\r\nmailbox:b\r\n*1\r\n*2\r\n$3\r\n1-0\r\n*4\r\n$4\r\nkind\r\n$3\r\nack\r\n$5\r\nissue\r\n$1\r\n7\r\n";
    assert.deepEqual(d.feed(Buffer.from(wire)), [[["mailbox:b", [["1-0", ["kind", "ack", "issue", "7"]]]]]]);
  });
});
