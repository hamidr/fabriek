// The decider as the pi extension that runs in its own cage (ADR-034 point
// 1). Every so often, and whenever an actor says something, it reads the
// board with its read-only token and the ready set off the bus, renders the
// four-part prompt, and lets the model choose; each tool call goes through
// the decider's gate and then to the commands stream, where the executor
// validates it again against the board and acts or refuses.
//
// Environment, as for a role's session, plus:
//   CAGEWORKS_POLICY      the policy file the machine bound in, if any
//   CAGEWORKS_HOME_HOST   this cage's home as the machine sees it, so a file
//                         command can name files the executor can open
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { BusClient } from "../bus/client.js";
import { ForgeClient } from "../forge/client.js";
import { readDeclaration } from "../declaration.js";
import { parseMessage, toFields } from "../messages.js";
import { Decider, type Commands, type IssueView, type Snapshot } from "./core.js";

const STREAM_CAP = 1000;
const TICK_MS = 30000;
const STATE_LABELS = new Set(["assigning", "assigned", "blocked", "memory"]);

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

export default function decider(pi: ExtensionAPI): void {
  const declaration = readDeclaration(readFileSync(env("CAGEWORKS_DECLARATION"), "utf8"));
  const [busHost, busPort] = env("CAGEWORKS_BUS").split(":");
  const [owner, repo] = env("CAGEWORKS_REPOSITORY").split("/");
  const forge = new ForgeClient({ base: env("CAGEWORKS_FORGE"), owner: owner ?? "", repo: repo ?? "", tokenFile: env("CAGEWORKS_FORGE_TOKEN") });
  const ceiling = declaration.resources.tokens;
  const homeInside = process.env["HOME"] ?? "/root";
  const homeHost = process.env["CAGEWORKS_HOME_HOST"] ?? homeInside;

  let context: ExtensionContext | undefined;
  let client: BusClient | undefined;
  let stopped = false;
  const ready = new Set<string>();
  let busy = false;

  const commands: Commands = {
    async send(c) {
      await client?.xadd("commands", { json: JSON.stringify(c) }, STREAM_CAP);
    },
  };
  const core = new Decider({ declaration, policy: readOr(process.env["CAGEWORKS_POLICY"]), commands });

  async function snapshot(): Promise<Snapshot> {
    const raw = await forge.call<{ number: number; title: string; labels: { name: string }[]; assignees: { login: string }[] | null }[]>(
      "GET",
      `/repos/${owner}/${repo}/issues?state=open&type=issues&limit=100`,
    );
    const issues: IssueView[] = [];
    for (const r of raw) {
      const labels = r.labels.map((l) => l.name);
      if (labels.includes("memory")) continue;
      const thread = await forge.thread(r.number);
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
    if (ceiling) {
      const r = await fetch(`http://${env("CAGEWORKS_PROXY")}/status`).catch(() => null);
      const counts = r && r.ok ? ((await r.json()) as Record<string, number>) : {};
      routing = (counts["total"] ?? 0) < ceiling * 0.9;
    }
    return { issues, ready: [...ready], routing };
  }

  async function think(): Promise<void> {
    if (busy || stopped || !context) return;
    if (!context.isIdle()) return;
    busy = true;
    try {
      pi.sendUserMessage(core.prompt(await snapshot()));
    } catch (e) {
      process.stderr.write(`decider: ${String(e)}\n`);
    } finally {
      busy = false;
    }
  }

  /** The ready set, kept from every role's control stream. */
  async function listen(): Promise<void> {
    const streams: Record<string, string> = {};
    for (const role of Object.keys(declaration.roles)) streams[`control:${role}`] = "0-0";
    while (!stopped) {
      try {
        if (!client || client.closed) {
          client = await BusClient.connect({
            host: busHost ?? "127.0.0.1",
            port: Number(busPort ?? "6379"),
            user: "decider",
            password: readFileSync(env("CAGEWORKS_BUS_PASSWORD"), "utf8").trim(),
          });
        }
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
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    context = ctx;
    void listen();
    setInterval(() => void think(), TICK_MS).unref();
    await think();
  });

  pi.on("session_shutdown", async () => {
    stopped = true;
    client?.close();
  });

  const result = (r: { ok: true } | { ok: false; reason: string }) => ({
    content: [{ type: "text" as const, text: r.ok ? "sent to the executor" : `refused: ${r.reason}` }],
    details: {},
  });

  pi.registerTool({
    name: "assign",
    label: "Assign",
    description: "Send an issue to a ready role that provides what its stage needs.",
    parameters: Type.Object({ issue: Type.Integer(), role: Type.String() }),
    async execute(_id, p) { return result(await core.command({ verb: "assign", ...p })); },
  });
  pi.registerTool({
    name: "retry",
    label: "Retry",
    description: "Send a failed issue back to the role that had it, with its previous outcome.",
    parameters: Type.Object({ issue: Type.Integer() }),
    async execute(_id, p) { return result(await core.command({ verb: "retry", ...p })); },
  });
  pi.registerTool({
    name: "block",
    label: "Block",
    description: "Mark an issue as waiting on another.",
    parameters: Type.Object({ issue: Type.Integer(), on: Type.Integer() }),
    async execute(_id, p) { return result(await core.command({ verb: "block", ...p })); },
  });
  pi.registerTool({
    name: "file",
    label: "File",
    description: "Open a new issue at a stage, from a title and a body you give here; they are written to files first.",
    parameters: Type.Object({ title: Type.String(), body: Type.String(), stage: Type.String() }),
    async execute(_id, p) {
      const dir = `filed/${Date.now()}`;
      mkdirSync(`${homeInside}/${dir}`, { recursive: true });
      writeFileSync(`${homeInside}/${dir}/title`, p.title);
      writeFileSync(`${homeInside}/${dir}/body`, p.body);
      return result(await core.command({ verb: "file", titleFile: `${homeHost}/${dir}/title`, bodyFile: `${homeHost}/${dir}/body`, stage: p.stage }));
    },
  });
  pi.registerTool({
    name: "push",
    label: "Push",
    description: "Push a role's branch to the forge and open its pull request.",
    parameters: Type.Object({ role: Type.String() }),
    async execute(_id, p) { return result(await core.command({ verb: "push", ...p })); },
  });
  pi.registerTool({
    name: "stop",
    label: "Stop",
    description: "End a role's running turn. Its task stays with it.",
    parameters: Type.Object({ role: Type.String() }),
    async execute(_id, p) { return result(await core.command({ verb: "stop", ...p })); },
  });
  pi.registerTool({
    name: "wait",
    label: "Wait",
    description: "Nothing should happen now. Say why in one line.",
    parameters: Type.Object({ why: Type.String() }),
    async execute(_id, p) { return { content: [{ type: "text" as const, text: `waiting: ${p.why}` }], details: {} }; },
  });
}
