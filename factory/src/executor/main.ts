// The executor as a service on the machine (ADR-034 point 2). Reads what the
// build and fabriek up put there, connects to the bus and the board as the
// executor, reconciles, starts every role's session, and then loops: what
// actors say on their control streams, what the decider asks on commands,
// what the operator asks on operator, and what the board shows as outcomes.
//
// Files it reads: /etc/fabriek/declaration.json and bridge.json (the
// build's), and under the state directory the bus password and forge token
// fabriek up made for it.
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { BusClient } from "../bus/client.js";
import { ForgeClient } from "../forge/client.js";
import { readDeclaration } from "../declaration.js";
import { parseMessage, toFields, type Message } from "../messages.js";
import { parseCommand } from "../vocabulary.js";
import { Executor, type Bus, type Spend, type Streams } from "./core.js";
import { ForgeBoard } from "./forge.js";
import { RoleSessions, sessionCommand } from "./sessions.js";
import { resumeFrom, remember } from "./cursor.js";
import { CloneGit } from "./git.js";
import { streamsOf } from "../bus/subjects.js";
import { spendByRole } from "./spend.js";

const ETC = process.env["FABRIEK_ETC"] ?? "/etc/fabriek";
const STATE = process.env["FABRIEK_STATE"] ?? "/var/lib/nixcage";
const STREAM_CAP = 10000;
/** What the probes stream keeps: the operator watches it live and nothing persists it (roadmap 2.2). */
const PROBES_CAP = 10000;

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
  const repository = `${factory}-operator/${factory}`;
  const forgeBase = `http://${plan.forgejo}/api/v1`;
  const operatorToken = `${STATE}/forge/operator-token`;

  const forge = new ForgeClient({ base: forgeBase, owner: `${factory}-operator`, repo: factory, factory, tokenFile: operatorToken });
  const board = new ForgeBoard(forge, `/repos/${repository}`, factory);

  // Memory streams go with the server, as Valkey's keys did, so the
  // account's are made at every connect and before anything is read or
  // reconciled (ADR-069 point 5). The executor is the account's one
  // manager; a role that connects first finds no stream and retries.
  const held = [...Object.keys(declaration.roles), "decider", "executor"];
  const connect = async () => {
    const c = await BusClient.connect({
      host: busHost ?? "127.0.0.1",
      port: Number(busPort ?? "4222"),
      user: "executor",
      password: readFileSync(`${STATE}/bus/executor`, "utf8").trim(),
    });
    for (const s of streamsOf(held)) await c.ensureStream(s.name, s.subjects, s.name === "probes" ? PROBES_CAP : STREAM_CAP);
    return c;
  };
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
  // The trace of an attempt is cut from the streams as they stand (ADR-051);
  // the executor's user may read every stream and this reads two.
  const observed: Streams = {
    async range(stream, from, to) {
      return client.xrange(stream, from, to);
    },
  };
  const sessions = new RoleSessions({
    factory,
    log,
    command: sessionCommand(process.env),
    // At the ceiling the proxy refuses every request, so a decider started
    // there could not think; it is held until the count is below it again,
    // which today means the proxy restarted with the machine. Roles are
    // restarted as ever: an idle actor spends nothing.
    async mayRestart(role) {
      if (role !== "decider" || !(await executor.atCeiling())) return true;
      log("the ceiling is reached; the decider is held");
      await publish("decider_held", { ceiling: declaration.resources.tokens });
      return false;
    },
  });
  const git = new CloneGit({
    clone: `${STATE}/factories/${factory}`,
    forgeUrl: `http://${plan.forgejo}/${repository}.git`,
    forgeTokenFile: operatorToken,
    record: async () => JSON.stringify(await forge.call("GET", `/repos/${repository}/issues?state=all&type=issues&limit=1000`), null, 2),
  });

  const executor = new Executor({ declaration, workflow, board, bus, sessions, git, spend, streams: observed });
  const roles = Object.keys(declaration.roles);
  const streams: Record<string, string> = { commands: "$", operator: "$" };
  for (const r of roles) streams[`control:${r}`] = "$";

  const publish = (kind: string, payload: unknown) =>
    client.xadd("events:executor", toFields({ kind: "event", name: kind, payload }), STREAM_CAP).catch(() => undefined);

  await executor.reconcile();
  log("reconciled");
  // Read from where each stream is now, and only then start the sessions:
  // an actor's ready that lands before the first read would be missed by
  // "$", and a role never heard ready is never assigned. Found on a host,
  // where a scripted actor is ready in milliseconds.
  for (const k of Object.keys(streams)) streams[k] = await client.lastId(k);
  // The operator's stream is a queue of interventions, and one filed while
  // the executor was down or reconciling (up restarts it) is owed an answer:
  // read from the id last read, kept across restarts (before it is acted
  // on, so a crash mid-way skips one rather than files it twice), and from
  // the tail only where none was kept yet.
  const operatorCursor = `${STATE}/operator-cursor`;
  streams["operator"] = resumeFrom(operatorCursor, streams["operator"] ?? "$");
  for (const r of roles) await sessions.start(r);
  await sessions.start("decider");
  log(`sessions started for ${roles.join(", ")} and the decider`);

  let lastOutcomes = 0;
  for (;;) {
    try {
      if (client.closed) {
        // Read on from the ids already held: a bus that restarted is empty
        // and hands out later ids, so nothing an actor re-announces is
        // missed, and nothing old is heard twice.
        client = await connect();
        log("bus reconnected");
      }
      const batches = await client.xreadMany(streams, 2000);
      for (const [stream, entries] of Object.entries(batches)) {
        for (const e of entries) {
          streams[stream] = e.id;
          if (stream === "operator") remember(operatorCursor, e.id);
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
        if (sessions.held().has("decider") && !(await executor.atCeiling())) {
          log("the count is below the ceiling; the decider is started again");
          await publish("decider_resumed", {});
          await sessions.start("decider");
        }
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
