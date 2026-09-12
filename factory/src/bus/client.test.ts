// A client of the bus: connects as one user, authenticates, and speaks the
// stream verbs. Driven against a fake Valkey on a local socket that records
// what it was asked and answers what a real one would.
import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server, type Socket } from "node:net";
import { Decoder, encode } from "./resp.js";
import { BusClient } from "./client.js";

interface Fake {
  server: Server;
  port: number;
  asked: string[][];
  close(): Promise<void>;
}

async function fakeValkey(answer: (cmd: string[]) => string): Promise<Fake> {
  const asked: string[][] = [];
  const sockets = new Set<Socket>();
  const server = createServer((socket: Socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    const d = new Decoder();
    socket.on("data", (chunk) => {
      for (const cmd of d.feed(chunk) as string[][]) {
        asked.push(cmd);
        socket.write(answer(cmd));
      }
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  // Closing drops every connection too, the way a bus that went away would.
  const close = () =>
    new Promise<void>((r) => {
      for (const s of sockets) s.destroy();
      server.close(() => r());
    });
  return { server, port, asked, close };
}

describe("a bus client", () => {
  const fakes: Fake[] = [];
  after(async () => {
    for (const f of fakes) await f.close();
  });

  it("given a user and a password, the first thing said is AUTH, and the password is never logged", async () => {
    const fake = await fakeValkey(() => "+OK\r\n");
    fakes.push(fake);
    const bus = await BusClient.connect({ host: "127.0.0.1", port: fake.port, user: "builder", password: "s3cret" });
    await bus.ping();
    assert.deepEqual(fake.asked[0], ["AUTH", "builder", "s3cret"]);
    assert.deepEqual(fake.asked[1], ["PING"]);
    assert.equal(String(bus).includes("s3cret"), false);
    bus.close();
  });

  it("xadd writes flat fields with a cap and returns the id", async () => {
    const fake = await fakeValkey((cmd) => (cmd[0] === "XADD" ? "$3\r\n1-0\r\n" : "+OK\r\n"));
    fakes.push(fake);
    const bus = await BusClient.connect({ host: "127.0.0.1", port: fake.port, user: "u", password: "p" });
    const id = await bus.xadd("findings:builder", { kind: "finding", text: "x" }, 1000);
    assert.equal(id, "1-0");
    assert.deepEqual(fake.asked[1], ["XADD", "findings:builder", "MAXLEN", "~", "1000", "*", "kind", "finding", "text", "x"]);
    bus.close();
  });

  it("xread blocks on a stream from an id and returns entries as fields", async () => {
    const fake = await fakeValkey((cmd) =>
      cmd[0] === "XREAD"
        ? "*1\r\n*2\r\n$9\r\nmailbox:b\r\n*1\r\n*2\r\n$3\r\n2-0\r\n*4\r\n$4\r\nkind\r\n$5\r\nabort\r\n$1\r\nx\r\n$1\r\ny\r\n"
        : "+OK\r\n",
    );
    fakes.push(fake);
    const bus = await BusClient.connect({ host: "127.0.0.1", port: fake.port, user: "u", password: "p" });
    const entries = await bus.xread("mailbox:b", "$", 100);
    assert.deepEqual(entries, [{ id: "2-0", fields: { kind: "abort", x: "y" } }]);
    assert.deepEqual(fake.asked[1], ["XREAD", "BLOCK", "100", "STREAMS", "mailbox:b", "$"]);
    bus.close();
  });

  it("xreadMany reads several streams from their own ids and returns each stream's entries", async () => {
    const fake = await fakeValkey((cmd) =>
      cmd[0] === "XREAD"
        ? "*1\r\n*2\r\n$15\r\ncontrol:builder\r\n*1\r\n*2\r\n$3\r\n5-0\r\n*2\r\n$4\r\nkind\r\n$5\r\nready\r\n"
        : "+OK\r\n",
    );
    fakes.push(fake);
    const bus = await BusClient.connect({ host: "127.0.0.1", port: fake.port, user: "u", password: "p" });
    const out = await bus.xreadMany({ "control:builder": "0-0", "control:reviewer": "3-0" }, 100);
    assert.deepEqual(out, { "control:builder": [{ id: "5-0", fields: { kind: "ready" } }] });
    assert.deepEqual(fake.asked[1], ["XREAD", "BLOCK", "100", "STREAMS", "control:builder", "control:reviewer", "0-0", "3-0"]);
    bus.close();
  });

  it("when the server answers an error, the call rejects with it", async () => {
    const fake = await fakeValkey((cmd) => (cmd[0] === "AUTH" ? "+OK\r\n" : "-NOPERM this user has no permissions\r\n"));
    fakes.push(fake);
    const bus = await BusClient.connect({ host: "127.0.0.1", port: fake.port, user: "u", password: "p" });
    await assert.rejects(bus.xadd("commands", { kind: "x" }, 10), /NOPERM/);
    bus.close();
  });

  it("when the connection drops, pending calls reject and the client says it is closed", async () => {
    const fake = await fakeValkey((cmd) => (cmd[0] === "AUTH" ? "+OK\r\n" : ""));
    fakes.push(fake);
    const bus = await BusClient.connect({ host: "127.0.0.1", port: fake.port, user: "u", password: "p" });
    const pending = bus.ping();
    await fake.close();
    await assert.rejects(pending, /closed/);
    assert.equal(bus.closed, true);
  });
});
