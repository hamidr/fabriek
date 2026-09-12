// The loop, as the pi extension that ships with the machine (ADR-035). This
// file binds the actor to pi and to the bus and the board the executor told
// it about through the environment, and holds nothing of its own: what the
// actor does is actor.ts, tested against fakes; what is here is glue.
//
// Environment, set by the executor when it starts the session:
//   CAGEWORKS_ROLE          the role this cage is
//   CAGEWORKS_CAPABILITIES  what it provides, comma separated
//   CAGEWORKS_BUS           host:port of the bus on the bridge
//   CAGEWORKS_FORGE         the forge's API base, http://host:port/api/v1
//   CAGEWORKS_REPOSITORY    owner/name on the forge
//   CAGEWORKS_BUS_PASSWORD  file holding this role's bus password
//   CAGEWORKS_FORGE_TOKEN   file holding this role's issue token
//   CAGEWORKS_BASE_BRANCH   the branch a task's commits are counted against
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync } from "node:fs";
import { BusClient } from "../bus/client.js";
import { ForgeClient } from "../forge/client.js";
import { parseMessage, toFields, type Message } from "../messages.js";
import { Actor, type Agent, type Board, type Bus, type Checks } from "./actor.js";

const STREAM_CAP = 10000;

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`cageworks: ${name} is not set; the executor starts a role session with it`);
  return v;
}

/** The bus as the actor speaks it: one control stream out, one mailbox in. */
class RoleBus implements Bus {
  constructor(
    private readonly client: BusClient,
    private readonly role: string,
  ) {}
  private write(stream: string, m: Message): Promise<string> {
    return this.client.xadd(stream, toFields(m), STREAM_CAP);
  }
  async announce(m: Message): Promise<void> {
    await this.write(`control:${this.role}`, m);
  }
  async ack(issue: number): Promise<void> {
    await this.write(`control:${this.role}`, { kind: "ack", issue });
  }
  async held(issues: number[]): Promise<void> {
    await this.write(`control:${this.role}`, { kind: "held", issues });
  }
  async event(name: string, payload: unknown): Promise<void> {
    await this.write(`events:${this.role}`, { kind: "event", name, payload });
  }
  async finding(text: string): Promise<void> {
    await this.write(`findings:${this.role}`, { kind: "finding", text });
  }
}

export default function cageworks(pi: ExtensionAPI): void {
  const role = env("CAGEWORKS_ROLE");
  const capabilities = env("CAGEWORKS_CAPABILITIES").split(",").filter(Boolean);
  const [busHost, busPort] = env("CAGEWORKS_BUS").split(":");
  const [owner, repo] = env("CAGEWORKS_REPOSITORY").split("/");
  const forge = new ForgeClient({ base: env("CAGEWORKS_FORGE"), owner: owner ?? "", repo: repo ?? "", tokenFile: env("CAGEWORKS_FORGE_TOKEN") });
  const baseBranch = process.env["CAGEWORKS_BASE_BRANCH"] ?? "main";

  let context: ExtensionContext | undefined;
  let client: BusClient | undefined;
  let actor: Actor | undefined;
  let stopped = false;

  const board: Board = {
    issue: (n) => forge.issue(n),
    thread: (n) => forge.thread(n),
    comment: (n, body) => forge.comment(n, body),
    memory: () => forge.memory(role),
    rewriteMemory: (n, body) => forge.rewriteMemory(n, body),
    blockedOn: () => forge.blockedOn(role),
  };

  const agent: Agent = {
    prompt: (text) => pi.sendUserMessage(text),
    steer: (text) => pi.sendUserMessage(text, { deliverAs: "steer" }),
    abort: () => context?.abort(),
    finish: () => {
      stopped = true;
      context?.shutdown();
    },
  };

  const checks: Checks = {
    async hasCommit() {
      const r = await pi.exec("git", ["rev-list", "--count", `${baseBranch}..HEAD`], { timeout: 10000 });
      return r.code === 0 && Number(r.stdout.trim()) > 0;
    },
  };

  /** Read the mailbox until shutdown, reconnecting when the bus goes away. */
  async function listen(): Promise<void> {
    let after = "$";
    while (!stopped) {
      try {
        if (!client || client.closed) {
          client = await BusClient.connect({
            host: busHost ?? "127.0.0.1",
            port: Number(busPort ?? "6379"),
            user: role,
            password: readFileSync(env("CAGEWORKS_BUS_PASSWORD"), "utf8").trim(),
          });
          after = "$";
          if (actor) await actor.reconnected();
        }
        for (const entry of await client.xread(`mailbox:${role}`, after, 5000)) {
          after = entry.id;
          try {
            await actor?.handle(parseMessage(entry.fields));
          } catch (e) {
            await actor?.publish("mailbox_refused", { id: entry.id, reason: String(e) });
          }
        }
      } catch {
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    context = ctx;
    client = await BusClient.connect({
      host: busHost ?? "127.0.0.1",
      port: Number(busPort ?? "6379"),
      user: role,
      password: readFileSync(env("CAGEWORKS_BUS_PASSWORD"), "utf8").trim(),
    });
    actor = new Actor({ role, capabilities, bus: new RoleBus(client, role), board, agent, checks });
    void listen();
    await actor.start();
  });

  pi.on("session_shutdown", async () => {
    stopped = true;
    client?.close();
  });

  const publish = (name: string) => async (event: object) => {
    const { type: _type, ...payload } = event as { type?: string } & Record<string, unknown>;
    await actor?.publish(name, payload);
  };
  pi.on("agent_start", publish("agent_start"));
  pi.on("agent_end", publish("agent_end"));
  pi.on("turn_start", publish("turn_start"));
  pi.on("turn_end", publish("turn_end"));
  pi.on("tool_call", publish("tool_call"));
  pi.on("tool_result", publish("tool_result"));

  pi.on("agent_settled", async () => {
    await actor?.settled();
  });

  pi.registerTool({
    name: "report_outcome",
    label: "Report outcome",
    description: "Report how this task ended: done, blocked, or failed, with a summary the record keeps.",
    parameters: Type.Object({
      status: Type.Union([Type.Literal("done"), Type.Literal("blocked"), Type.Literal("failed")]),
      summary: Type.String({ description: "What was done, or why it could not be" }),
    }),
    async execute(_id, params) {
      await actor?.reportOutcome(params);
      return { content: [{ type: "text", text: `outcome recorded: ${params.status}` }], details: {} };
    },
  });

  pi.registerTool({
    name: "update_memory",
    label: "Update memory",
    description: "Replace what this role remembers for its next task: conventions, where things live, what went wrong.",
    parameters: Type.Object({ body: Type.String() }),
    async execute(_id, params) {
      await actor?.updateMemory(params.body);
      return { content: [{ type: "text", text: "memory updated" }], details: {} };
    },
  });

  pi.registerTool({
    name: "share_finding",
    label: "Share a finding",
    description: "Tell every other role something worth knowing, on this role's findings stream.",
    parameters: Type.Object({ text: Type.String() }),
    async execute(_id, params) {
      await actor?.share(params.text);
      return { content: [{ type: "text", text: "shared" }], details: {} };
    },
  });
}
