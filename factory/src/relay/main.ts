// The relay (ADR-039 point 2): the bus as JSONL on stdout, one line per
// entry, for as long as the caller keeps the connection. Runs on the machine
// as the executor's bus user; the CLI's factory watch carries it over ssh.
// From the end by default, so a watcher sees what happens next; --from 0-0
// replays what the streams still hold.
import { readFileSync } from "node:fs";
import { BusClient } from "../bus/client.js";
import { readDeclaration } from "../declaration.js";
import { encodeLine, streamsFor } from "./format.js";

const ETC = process.env["CAGEWORKS_ETC"] ?? "/etc/cageworks";
const STATE = process.env["CAGEWORKS_STATE"] ?? "/var/lib/nixcage";

async function main(): Promise<void> {
  const from = process.argv.includes("--from") ? (process.argv[process.argv.indexOf("--from") + 1] ?? "$") : "$";
  const declaration = readDeclaration(readFileSync(`${ETC}/declaration.json`, "utf8"));
  const plan = JSON.parse(readFileSync(`${ETC}/bridge.json`, "utf8")) as { valkey: string };
  const [host, port] = plan.valkey.split(":");
  const client = await BusClient.connect({
    host: host ?? "127.0.0.1",
    port: Number(port ?? "6379"),
    user: "executor",
    password: readFileSync(`${STATE}/bus/executor`, "utf8").trim(),
  });
  const streams: Record<string, string> = {};
  for (const s of streamsFor(Object.keys(declaration.roles))) streams[s] = from;
  for (;;) {
    const batches = await client.xreadMany(streams, 5000);
    for (const [stream, entries] of Object.entries(batches)) {
      for (const e of entries) {
        streams[stream] = e.id;
        process.stdout.write(encodeLine(stream, e) + "\n");
      }
    }
  }
}

main().catch((e) => {
  process.stderr.write(`relay: ${String(e)}\n`);
  process.exit(1);
});
