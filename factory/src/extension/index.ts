// The loop, as the pi extension that ships with the machine (ADR-035). This
// file binds pi to the actor and holds nothing of its own: what the actor
// does is actor.ts, the bus and the board are bind.ts, and what is here is
// pi's agent and pi's tools. The environment the executor sets is read by
// bind.ts's fromEnvironment.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { bindActor, fromEnvironment, type Bound } from "./bind.js";
import type { Agent, Checks } from "./actor.js";

export default function cageworks(pi: ExtensionAPI): void {
  const world = fromEnvironment();
  let context: ExtensionContext | undefined;
  let bound: Bound | undefined;
  const actor = () => bound?.actor;

  const agent: Agent = {
    prompt: (text) => pi.sendUserMessage(text),
    steer: (text) => pi.sendUserMessage(text, { deliverAs: "steer" }),
    abort: () => context?.abort(),
    finish: () => {
      bound?.stop();
      context?.shutdown();
    },
  };

  const checks: Checks = {
    async hasCommit() {
      const r = await pi.exec("git", ["rev-list", "--count", `${world.baseBranch}..HEAD`], { timeout: 10000 });
      return r.code === 0 && Number(r.stdout.trim()) > 0;
    },
  };

  pi.on("session_start", async (_event, ctx) => {
    context = ctx;
    bound = bindActor({ ...world, agent, checks });
    await bound.start();
  });

  pi.on("session_shutdown", async () => {
    bound?.stop();
  });

  const publish = (name: string) => async (event: object) => {
    const { type: _type, ...payload } = event as { type?: string } & Record<string, unknown>;
    await actor()?.publish(name, payload);
  };
  pi.on("agent_start", publish("agent_start"));
  pi.on("agent_end", publish("agent_end"));
  pi.on("turn_start", publish("turn_start"));
  pi.on("turn_end", publish("turn_end"));
  pi.on("tool_call", publish("tool_call"));
  pi.on("tool_result", publish("tool_result"));

  pi.on("agent_settled", async () => {
    await actor()?.settled();
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
      await actor()?.reportOutcome(params);
      return { content: [{ type: "text", text: `outcome recorded: ${params.status}` }], details: {} };
    },
  });

  pi.registerTool({
    name: "update_memory",
    label: "Update memory",
    description: "Replace what this role remembers for its next task: conventions, where things live, what went wrong.",
    parameters: Type.Object({ body: Type.String() }),
    async execute(_id, params) {
      await actor()?.updateMemory(params.body);
      return { content: [{ type: "text", text: "memory updated" }], details: {} };
    },
  });

  pi.registerTool({
    name: "share_finding",
    label: "Share a finding",
    description: "Tell every other role something worth knowing, on this role's findings stream.",
    parameters: Type.Object({ text: Type.String() }),
    async execute(_id, params) {
      await actor()?.share(params.text);
      return { content: [{ type: "text", text: "shared" }], details: {} };
    },
  });
}
