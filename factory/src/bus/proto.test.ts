// The NATS protocol as the bus reads and writes it (ADR-069 point 6).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Decoder, connectLine, pubLine, subLine, type Message } from "./proto.js";

function frames(...chunks: string[]) {
  const d = new Decoder();
  return chunks.flatMap((c) => d.feed(c));
}

describe("the protocol's decoder", () => {
  it("reads the server's greeting and its keepalives", () => {
    const out = frames('INFO {"server_id":"x","max_payload":1048576}\r\nPING\r\n+OK\r\n');
    assert.deepEqual(
      out.map((f) => f.kind),
      ["INFO", "PING", "OK"],
    );
    assert.equal(out[0]?.kind === "INFO" && out[0].json["server_id"], "x");
  });

  it("reads a refusal in the server's own words", () => {
    const out = frames("-ERR 'Permissions Violation for Publish to \"control.tester\"'\r\n");
    assert.equal(out[0]?.kind, "ERR");
    assert.equal(out[0]?.kind === "ERR" && out[0].message, 'Permissions Violation for Publish to "control.tester"');
  });

  it("reads a message with its subject, its subscription and its reply", () => {
    const out = frames("MSG control.dev 3 _INBOX.dev.7 5\r\nhello\r\n");
    const m = out[0] as Message;
    assert.equal(m.kind, "MSG");
    assert.equal(m.subject, "control.dev");
    assert.equal(m.sid, "3");
    assert.equal(m.reply, "_INBOX.dev.7");
    assert.equal(m.payload, "hello");
    assert.equal(m.status, null);
  });

  it("reads a message that arrives in pieces, and only once it is whole", () => {
    const d = new Decoder();
    assert.deepEqual(d.feed("MSG findings.dev 2 11\r\nhello"), []);
    const out = d.feed(" world\r\n");
    assert.equal((out[0] as Message).payload, "hello world");
  });

  it("reads a header message's status, which is how a pull says it found nothing", () => {
    const out = frames("HMSG _INBOX.dev.1 4 28 28\r\nNATS/1.0 404 No Messages\r\n\r\n\r\n");
    const m = out[0] as Message;
    assert.equal(m.status, 404);
    assert.equal(m.description, "No Messages");
    assert.equal(m.payload, "");
  });

  it("reads a header message's headers beside its payload", () => {
    const body = "NATS/1.0\r\nNats-Stream: mailbox-dev\r\nNats-Sequence: 12\r\n\r\n";
    const out = frames(`HMSG mailbox.dev 5 ${body.length} ${body.length + 2}\r\n${body}hi\r\n`);
    const m = out[0] as Message;
    assert.equal(m.headers["Nats-Sequence"], "12");
    assert.equal(m.payload, "hi");
  });

  it("goes on after a line it does not know, rather than reading it as bytes", () => {
    const out = frames("XYZZY nothing\r\nPING\r\n");
    assert.deepEqual(
      out.map((f) => f.kind),
      ["PING"],
    );
  });
});

describe("the protocol's writer", () => {
  it("connects as the user, with headers, so a status reaches the reader", () => {
    const line = connectLine({ user: "acme-dev", password: "secret" });
    const json = JSON.parse(line.slice("CONNECT ".length).trim()) as Record<string, unknown>;
    assert.equal(json["user"], "acme-dev");
    assert.equal(json["pass"], "secret");
    assert.equal(json["headers"], true);
    assert.equal(json["verbose"], false);
  });

  it("publishes with a byte count, and with a reply subject when one is asked for", () => {
    assert.equal(pubLine("control.dev", "hi"), "PUB control.dev 2\r\nhi\r\n");
    assert.equal(pubLine("control.dev", "hi", "_INBOX.dev.1"), "PUB control.dev _INBOX.dev.1 2\r\nhi\r\n");
  });

  it("counts bytes and not characters, so a payload is never cut short", () => {
    const wide = String.fromCharCode(0x00e9);
    assert.equal(pubLine("events.dev", wide), `PUB events.dev 2\r\n${wide}\r\n`);
  });

  it("subscribes a subject to a subscription id", () => {
    assert.equal(subLine("_INBOX.acme-dev.>", "1"), "SUB _INBOX.acme-dev.> 1\r\n");
  });
});
