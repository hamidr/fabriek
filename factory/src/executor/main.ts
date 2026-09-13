// The executor as a service on the machine (ADR-034 point 2). Reads what the
// build and cageworks up put there, connects to the bus and the board as the
// executor, reconciles, starts every role's session, and then loops: what
// actors say on their control streams, what the decider asks on commands,
// what the operator asks on operator, and what the board shows as outcomes.
//
// Files it reads: /etc/cageworks/declaration.json and bridge.json (the
// build's), and under the state directory the bus password and forge token
// cageworks up made for it.
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { BusClient } from "../bus/client.js";
import { ForgeClient } from "../forge/client.js";
import { readDeclaration } from "../declaration.js";
import { parseMessage, toFields, type Message } from "../messages.js";
import { parseCommand } from "../vocabulary.js";
import { Executor, type Bus, type Spend } from "./core.js";
import { ForgeBoard } from "./forge.js";
import { RoleSessions } from "./sessions.js";
import { CloneGit } from "./git.js";
import { spendByRole } from "./spend.js";

const ETC = process.env["CAGEWORKS_ETC"] ?? "/etc/cageworks";
const STATE = process.env["CAGEWORKS_STATE"] ?? "/var/lib/nixcage";
const STREAM_CAP = 10000;

function log(line: string): void {
  process.stdout.write(`${new Date().toISOString()} ${line}\n`);
}

async function main(): Promise<void> {
  const declaration = readDeclaration(await readFile(`${ETC}/declaration.json`, "utf8"));
  const plan = JSON.parse(await readFile(`${ETC}/bridge.json`, "utf8")) as { valkey: string; forgejo: string; proxy: string; cages: Record<string, string> };
  const factory = declaration.name;
  const workflow = Object.keys(declaration.workflows)[0];
  if (!workflow) throw new Error("the declaration has no workflow");
  const [busHost, busPort] = plan.valkey.split(":");
  const repository = `operator/${factory}`;
  const forgeBase = `http://${plan.forgejo}/api/v1`;
  const operatorToken = `${STATE}/forge/operator-token`;

  const forge = new ForgeClient({ base: forgeBase, owner: "operator", repo: factory, tokenFile: operatorToken });
  const board = new ForgeBoard(forge, `/repos/${repository}`);

  const connect = () =>
    BusClient.connect({
      host: busHost ?? "127.0.0.1",
      port: Number(busPort ?? "6379"),
      user: "executor",
      password: readFileSync(`${STATE}/bus/executor`, "utf8").trim(),
    });
  let client = await connect();
  const bus: Bus = {
    async send(role, message) {
      await client.xadd(`mailbox:${role}`, toFields(message), STREAM_CAP);
    },
  };
  const spend: Spend & { counts(): Promise<Record<string, number>> } = {
    async counts() {
      const r = await fetch(`http://${plan.proxy}/status`).catch(() => null);
      if (!r || !r.ok) return {};
      return (await r.json()) as Record<string, number>;
    },
    async total() {
      return (await this.counts())["total"] ?? 0;
    },
  };
  const sessions = new RoleSessions({ factory, log });
  const git = new CloneGit({
    clone: `${STATE}/factories/${factory}`,
    forgeUrl: `http://${plan.forgejo}/${repository}.git`,
    forgeTokenFile: operatorToken,
    record: async () => JSON.stringify(await forge.call("GET", `/repos/${repository}/issues?state=all&type=issues&limit=1000`), null, 2),
  });

  const executor = new Executor({ declaration, workflow, board, bus, sessions, git, spend });
  const roles = Object.keys(declaration.roles);
  const streams: Record<string, string> = { commands: "$", operator: "$" };
  for (const r of roles) streams[`control:${r}`] = "$";

  const publish = (kind: string, payload: unknown) =>
    client.xadd("events:executor", toFields({ kind: "event", name: kind, payload }), STREAM_CAP).catch(() => undefined);

  await executor.reconcile();
  log("reconciled");
  for (const r of roles) await sessions.start(r);
  await sessions.start("decider");
  log(`sessions started for ${roles.join(", ")} and the decider`);

  let lastOutcomes = 0;
  for (;;) {
    try {
      if (client.closed) {
        client = await connect();
        for (const k of Object.keys(streams)) streams[k] = "$";
        log("bus reconnected");
      }
      const batches = await client.xreadMany(streams, 2000);
      for (const [stream, entries] of Object.entries(batches)) {
        for (const e of entries) {
          streams[stream] = e.id;
          if (stream.startsWith("control:")) {
            const role = stream.slice("control:".length);
            try {
              executor.heard(role, parseMessage(e.fields));
            } catch (err) {
              await publish("control_refused", { role, reason: String(err) });
            }
          } else {
            try {
              const raw = JSON.parse(e.fields["json"] ?? "{}") as { op?: string };
              if (stream === "operator" && raw.op === "mirror") {
                await executor.mirror();
                await publish("mirrored", {});
                continue;
              }
              if (stream === "operator" && raw.op === "steer") {
                const { role, text } = raw as { role?: string; text?: string };
                if (role && text && role in declaration.roles) await bus.send(role, { kind: "steer", text });
                await publish("steered", { role });
                continue;
              }
              const command = parseCommand(raw);
              const result = await executor.apply(command, { readFile: (p) => readFile(p, "utf8") });
              await publish("command", { from: stream, command, result });
              if (!result.ok) log(`${stream}: ${command.verb} refused: ${result.reason}`);
            } catch (err) {
              await publish("command_refused", { from: stream, reason: String(err) });
            }
          }
        }
      }
      await executor.settle();
      if (Date.now() - lastOutcomes > 10000) {
        await executor.checkOutcomes();
        lastOutcomes = Date.now();
        await publish("board", await executor.snapshot());
        await publish("spend", spendByRole(await spend.counts(), plan.cages));
      }
    } catch (err) {
      log(`loop: ${String(err)}`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

main().catch((err) => {
  log(`executor: ${String(err)}`);
  process.exit(1);
});
