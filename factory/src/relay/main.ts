// The relay (ADR-039 point 2): the bus as JSONL on stdout, one line per
// entry, for as long as the caller keeps the connection. Runs on the machine
// as the executor's bus user; the CLI's factory watch carries it over ssh.
// From the end by default, so a watcher sees what happens next; --from 0-0
// replays what the streams still hold; --stream narrows to the streams
// named.
import { readFileSync } from "node:fs";
import { BusClient } from "../bus/client.js";
import { readDeclaration } from "../declaration.js";
import { relayArgs } from "./args.js";
import { streamsFor } from "./format.js";
import { tail } from "./tail.js";

const ETC = process.env["FABRIEK_ETC"] ?? "/etc/fabriek";
const STATE = process.env["FABRIEK_STATE"] ?? "/var/lib/nixcage";

async function main(): Promise<void> {
  const declaration = readDeclaration(readFileSync(`${ETC}/declaration.json`, "utf8"));
  const { from, streams } = relayArgs(process.argv.slice(2), streamsFor(Object.keys(declaration.roles)));
  const plan = JSON.parse(readFileSync(`${ETC}/bridge.json`, "utf8")) as { valkey: string };
  const [host, port] = plan.valkey.split(":");
  await tail({
    streams,
    from,
    connect: () =>
      BusClient.connect({
        host: host ?? "127.0.0.1",
        port: Number(port ?? "6379"),
        user: "executor",
        password: readFileSync(`${STATE}/bus/executor`, "utf8").trim(),
      }),
    write: (line) => process.stdout.write(line + "\n"),
    retry: () => new Promise((r) => setTimeout(r, 2000)),
  });
}

main().catch((e) => {
  process.stderr.write(`relay: ${String(e)}\n`);
  process.exit(1);
});
