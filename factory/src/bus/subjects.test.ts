// Where a stream's old name lands on NATS (ADR-069 points 5 and 7).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { place, streamsOf, sequenceOf, idOf, readId } from "./subjects.js";

describe("a stream's place", () => {
  it("gives a role's mailbox a stream of its own, so a pull permission bounds it", () => {
    assert.deepEqual(place("mailbox:dev"), { subject: "mailbox.dev", stream: "mailbox-dev", filter: null });
    assert.deepEqual(place("control:dev"), { subject: "control.dev", stream: "control-dev", filter: null });
    assert.deepEqual(place("events:executor"), { subject: "events.executor", stream: "events-executor", filter: null });
  });

  it("puts every role's findings in one stream, which a reader filters by subject", () => {
    assert.deepEqual(place("findings:dev"), { subject: "findings.dev", stream: "findings", filter: "findings.dev" });
  });

  it("leaves a stream that names no role as it is", () => {
    assert.deepEqual(place("commands"), { subject: "commands", stream: "commands", filter: null });
    assert.deepEqual(place("operator"), { subject: "operator", stream: "operator", filter: null });
    assert.deepEqual(place("probes"), { subject: "probes", stream: "probes", filter: null });
  });
});

describe("the streams a factory's account holds", () => {
  it("is three per role and four for the factory", () => {
    const streams = streamsOf(["dev", "reviewer"]);
    assert.equal(streams.length, 3 * 2 + 4);
    assert.deepEqual(
      streams.filter((s) => s.name === "findings"),
      [{ name: "findings", subjects: ["findings.*"] }],
    );
    assert.deepEqual(streams[0], { name: "mailbox-dev", subjects: ["mailbox.dev"] });
  });
});

describe("what a delivered message says about itself", () => {
  it("reads the stream sequence off the subject JetStream asks acknowledgement on", () => {
    assert.equal(sequenceOf("$JS.ACK.mailbox-dev.c1.1.7.7.1758543210000000000.0"), 7);
  });

  it("reads it from the longer subject too, the one carrying a domain and an account", () => {
    assert.equal(sequenceOf("$JS.ACK.hub.abc123.mailbox-dev.c1.1.7.7.1758543210000000000.0"), 7);
  });

  it("answers nothing for a message with no reply subject at all", () => {
    assert.equal(sequenceOf(null), null);
    assert.equal(sequenceOf("_INBOX.dev.1"), null);
  });
});

describe("an entry's id", () => {
  it("is the stream's creation time and the entry's sequence", () => {
    assert.equal(idOf(1758543210000, 7), "1758543210000-7");
    assert.deepEqual(readId("1758543210000-7"), { created: 1758543210000, sequence: 7 });
  });

  it("is not read from a word that is no id, so a reader falls back rather than seeking to nowhere", () => {
    assert.equal(readId("$"), null);
    assert.equal(readId("nonsense"), null);
  });

  it("orders entries of one stream by sequence, and two streams' by creation", () => {
    const a = readId(idOf(100, 9));
    const b = readId(idOf(200, 1));
    assert.ok(a && b);
    assert.ok(a.created < b.created);
  });
});
