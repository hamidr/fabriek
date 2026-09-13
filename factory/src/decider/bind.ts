// The decider bound to the world (ADR-034 point 1): the board read with its
// read-only token, the ready set kept off every role's control stream, the
// commands stream written through the core's gate, and a think whenever an
// actor said something and every so often besides. What judges is the
// think the caller hands in: pi's model in index.ts, a script in
// fake-decider. Written against the two interfaces below so it is asserted
// without a socket.
//
// Environment, as for a role's session, plus:
//   CAGEWORKS_DECLARATION the declaration file
//   CAGEWORKS_POLICY      the policy file the machine bound in, if any
//   CAGEWORKS_PROXY       host:port of the proxy, for the soft limit
import { readFileSync } from "node:fs";
import { BusClient, type Entry } from "../bus/client.js";
import { ForgeClient } from "../forge/client.js";
import { readDeclaration, type Declaration } from "../declaration.js";
import { parseMessage } from "../messages.js";
import { Decider, type IssueView, type Snapshot } from "./core.js";

const STREAM_CAP = 1000;
const STATE_LABELS = new Set(["assigning", "assigned", "blocked", "memory"]);

export interface DeciderBus {
  closed: boolean;
  xadd(stream: string, fields: Record<string, string>, maxlen: number): Promise<string>;
  xreadMany(after: Record<string, string>, block: number): Promise<Record<string, Entry[]>>;
  close(): void;
}

export type DeciderForge = Pick<ForgeClient, "call" | "thread">;

export interface DeciderBindOptions {
  declaration: Declaration;
  policy: string | null;
  connect(): Promise<DeciderBus>;
  forge: DeciderForge;
  /** The spend so far, for the soft limit; absent means no proxy to ask. */
  spent?(): Promise<number>;
  /** Judge: given the prompt and the board it was rendered from, ask through core.command. */
  think(prompt: string, snapshot: Snapshot): Promise<void>;
  tickMs?: number;
  retryMs?: number;
}

export interface BoundDecider {
  core: Decider;
  start(): Promise<void>;
  stop(): void;
  snapshot(): Promise<Snapshot>;
}

export function bindDecider(o: DeciderBindOptions): BoundDecider {
  let client: DeciderBus | undefined;
  let stopped = false;
  let busy = false;
  const ready = new Set<string>();
  const [owner, repo] = ["operator", o.declaration.name];
  const ceiling = o.declaration.resources.tokens;

  const core = new Decider({
    declaration: o.declaration,
    policy: o.policy,
    commands: {
      async send(c) {
        await client?.xadd("commands", { json: JSON.stringify(c) }, STREAM_CAP);
      },
    },
  });

  async function snapshot(): Promise<Snapshot> {
    const raw = await o.forge.call<{ number: number; title: string; labels: { name: string }[]; assignees: { login: string }[] | null }[]>(
      "GET",
      `/repos/${owner}/${repo}/issues?state=open&type=issues&limit=100`,
    );
    const issues: IssueView[] = [];
    for (const r of raw) {
      const labels = r.labels.map((l) => l.name);
      if (labels.includes("memory")) continue;
      const thread = await o.forge.thread(r.number);
      const attempts = thread.filter((c) => c.by === "executor" && /^attempt \d+ started/.test(c.body)).length;
      const assignee = r.assignees?.[0]?.login ?? null;
      const lastOutcome = [...thread].reverse().find((c) => c.by === assignee && c.body.startsWith("outcome:"))?.body ?? null;
      issues.push({
        number: r.number,
        title: r.title,
        stage: labels.find((l) => !STATE_LABELS.has(l)) ?? null,
        assignee,
        attempts,
        blocked: labels.includes("blocked"),
        lastOutcome,
      });
    }
    let routing = true;
    if (ceiling && o.spent) routing = (await o.spent()) < ceiling * 0.9;
    return { issues, ready: [...ready], routing };
  }

  /** One judgement at a time; a change that lands mid-thought is thought about next, not dropped. */
  let again = false;
  async function think(): Promise<void> {
    if (stopped) return;
    if (busy) {
      again = true;
      return;
    }
    busy = true;
    try {
      do {
        again = false;
        const s = await snapshot();
        await o.think(core.prompt(s), s);
      } while (again && !stopped);
    } catch (e) {
      process.stderr.write(`decider: ${String(e)}\n`);
    } finally {
      busy = false;
    }
  }

  /** The ready set, kept from every role's control stream. */
  async function listen(): Promise<void> {
    const streams: Record<string, string> = {};
    for (const role of Object.keys(o.declaration.roles)) streams[`control:${role}`] = "0-0";
    while (!stopped) {
      try {
        if (!client || client.closed) client = await o.connect();
        const batches = await client.xreadMany(streams, 5000);
        let changed = false;
        for (const [stream, entries] of Object.entries(batches)) {
          const role = stream.slice("control:".length);
          for (const e of entries) {
            streams[stream] = e.id;
            try {
              const m = parseMessage(e.fields);
              if (m.kind === "ready") ready.add(role);
              if (m.kind === "ack") ready.delete(role);
              changed = true;
            } catch {
              // a malformed entry is the writer's problem, not the decider's
            }
          }
        }
        if (changed) await think();
      } catch {
        await new Promise((r) => setTimeout(r, o.retryMs ?? 2000));
      }
    }
  }

  return {
    core,
    snapshot,
    async start() {
      client = await o.connect();
      void listen();
      setInterval(() => void think(), o.tickMs ?? 30000).unref();
      await think();
    },
    stop() {
      stopped = true;
      client?.close();
    },
  };
}

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`cageworks: ${name} is not set; the executor starts the decider with it`);
  return v;
}

function readOr(path: string | undefined): string | null {
  if (!path) return null;
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

/** The binding's inputs as the executor hands them to the decider's session, read once. */
export function fromEnvironment(): Pick<DeciderBindOptions, "declaration" | "policy" | "connect" | "forge" | "spent"> {
  const declaration = readDeclaration(readFileSync(env("CAGEWORKS_DECLARATION"), "utf8"));
  const [busHost, busPort] = env("CAGEWORKS_BUS").split(":");
  const [owner, repo] = env("CAGEWORKS_REPOSITORY").split("/");
  const proxy = process.env["CAGEWORKS_PROXY"];
  const spent = async (): Promise<number> => {
    const r = await fetch(`http://${proxy}/status`).catch(() => null);
    const counts = r && r.ok ? ((await r.json()) as Record<string, number>) : {};
    return counts["total"] ?? 0;
  };
  return {
    ...(proxy ? { spent } : {}),
    declaration,
    policy: readOr(process.env["CAGEWORKS_POLICY"]),
    connect: () =>
      BusClient.connect({
        host: busHost ?? "127.0.0.1",
        port: Number(busPort ?? "6379"),
        user: "decider",
        password: readFileSync(env("CAGEWORKS_BUS_PASSWORD"), "utf8").trim(),
      }),
    forge: new ForgeClient({ base: env("CAGEWORKS_FORGE"), owner: owner ?? "", repo: repo ?? "", tokenFile: env("CAGEWORKS_FORGE_TOKEN") }),
  };
}
