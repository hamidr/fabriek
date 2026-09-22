// The actor bound to the world (ADR-035): the bus it announces on and reads
// its mailbox from, connecting again when the bus goes away, and the board it
// reads and writes. What the actor does is actor.ts; what drives it is the
// agent the caller hands in, pi's in index.ts and a script's in fake/actor.ts.
// Written against the two interfaces below so it is asserted without a
// socket; the environment reader at the bottom is what both callers share.
//
// Environment, set by the executor when it starts the session:
//   FABRIEK_ROLE          the role this cage is
//   FABRIEK_CAPABILITIES  what it provides, comma separated
//   FABRIEK_SPECIALISTS   who it is composed of, comma separated, may be empty
//   FABRIEK_BUS           host:port of the bus on the bridge
//   FABRIEK_FORGE         the forge's API base, http://host:port/api/v1
//   FABRIEK_REPOSITORY    owner/name on the forge
//   FABRIEK_BUS_PASSWORD  file holding this role's bus password
//   FABRIEK_FORGE_TOKEN   file holding this role's issue token
//   FABRIEK_BASE_BRANCH   the branch a task's commits are counted against
import { readFileSync } from "node:fs";
import { BusClient, type Entry } from "../bus/client.js";
import { ForgeClient } from "../forge/client.js";
import { accountOf } from "../forge/account.js";
import { parseMessage, toFields, type Message } from "../messages.js";
import { Actor, type Agent, type Board, type Bus, type Checks, type Tree } from "./actor.js";

const STREAM_CAP = 10000;

/** What the binding needs of a bus connection. */
export interface ActorBus {
  closed: boolean;
  xadd(stream: string, fields: Record<string, string>, maxlen: number): Promise<string>;
  xread(stream: string, after: string, block: number): Promise<Entry[]>;
  close(): void;
}

/** What the binding needs of the forge. */
export type ActorForge = Pick<ForgeClient, "issue" | "thread" | "comment" | "memory" | "rewriteMemory" | "blockedOn">;

export interface BindOptions {
  role: string;
  capabilities: string[];
  specialists?: string[];
  connect(): Promise<ActorBus>;
  forge: ActorForge;
  agent: Agent;
  checks: Checks;
  tree: Tree;
  /** The pause before connecting again. */
  retryMs?: number;
}

export interface Bound {
  actor: Actor;
  /** Connect, announce, and read the mailbox until stop. */
  start(): Promise<void>;
  stop(): void;
}

/** The bus as the actor speaks it: one control stream out, one mailbox in. */
class RoleBus implements Bus {
  constructor(
    private readonly client: () => ActorBus | undefined,
    private readonly role: string,
  ) {}
  private async write(stream: string, m: Message): Promise<void> {
    await this.client()?.xadd(stream, toFields(m), STREAM_CAP);
  }
  announce(m: Message): Promise<void> {
    return this.write(`control:${this.role}`, m);
  }
  ack(issue: number): Promise<void> {
    return this.write(`control:${this.role}`, { kind: "ack", issue });
  }
  held(issues: number[]): Promise<void> {
    return this.write(`control:${this.role}`, { kind: "held", issues });
  }
  event(name: string, payload: unknown): Promise<void> {
    return this.write(`events:${this.role}`, { kind: "event", name, payload });
  }
  finding(text: string): Promise<void> {
    return this.write(`findings:${this.role}`, { kind: "finding", text });
  }
}

export function bindActor(o: BindOptions): Bound {
  let client: ActorBus | undefined;
  let stopped = false;
  const board: Board = {
    issue: (n) => o.forge.issue(n),
    thread: (n) => o.forge.thread(n),
    comment: (n, body) => o.forge.comment(n, body),
    memory: () => o.forge.memory(o.role),
    rewriteMemory: (n, body) => o.forge.rewriteMemory(n, body),
    blockedOn: () => o.forge.blockedOn(o.role),
  };
  const actor = new Actor({ role: o.role, capabilities: o.capabilities, specialists: o.specialists ?? [], bus: new RoleBus(() => client, o.role), board, agent: o.agent, checks: o.checks, tree: o.tree });

  /** Read the mailbox until stopped, reconnecting when the bus goes away. */
  async function listen(): Promise<void> {
    let after = "$";
    while (!stopped) {
      try {
        if (!client || client.closed) {
          client = await o.connect();
          after = "$";
          await actor.reconnected();
        }
        for (const entry of await client.xread(`mailbox:${o.role}`, after, 5000)) {
          after = entry.id;
          try {
            await actor.handle(parseMessage(entry.fields));
          } catch (e) {
            await actor.publish("mailbox_refused", { id: entry.id, reason: String(e) });
          }
        }
      } catch {
        await new Promise((r) => setTimeout(r, o.retryMs ?? 2000));
      }
    }
  }

  return {
    actor,
    async start() {
      client = await o.connect();
      // Announced before the mailbox is read: an assignment that arrived
      // first would be acked and then forgotten by the announce.
      await actor.start();
      void listen();
    },
    stop() {
      stopped = true;
      client?.close();
    },
  };
}

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`fabriek: ${name} is not set; the executor starts a role session with it`);
  return v;
}

/** The binding's inputs as the executor hands them to a session, read once. */
export function fromEnvironment(): Pick<BindOptions, "role" | "capabilities" | "specialists" | "connect" | "forge"> & { baseBranch: string } {
  const role = env("FABRIEK_ROLE");
  const [busHost, busPort] = env("FABRIEK_BUS").split(":");
  const [owner, repo] = env("FABRIEK_REPOSITORY").split("/");
  return {
    role,
    capabilities: env("FABRIEK_CAPABILITIES").split(",").filter(Boolean),
    specialists: (process.env["FABRIEK_SPECIALISTS"] ?? "").split(",").filter(Boolean),
    connect: () =>
      BusClient.connect({
        host: busHost ?? "127.0.0.1",
        port: Number(busPort ?? "4222"),
        user: accountOf(repo ?? "", role),
        password: readFileSync(env("FABRIEK_BUS_PASSWORD"), "utf8").trim(),
      }),
    forge: new ForgeClient({ base: env("FABRIEK_FORGE"), owner: owner ?? "", repo: repo ?? "", factory: repo ?? "", tokenFile: env("FABRIEK_FORGE_TOKEN") }),
    baseBranch: process.env["FABRIEK_BASE_BRANCH"] ?? "main",
  };
}
