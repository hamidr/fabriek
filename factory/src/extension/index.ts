// The loop, as the pi extension that ships with the machine (ADR-035). This
// file binds pi to the actor and holds nothing of its own: what the actor
// does is actor.ts, the bus and the board are bind.ts, and what is here is
// pi's agent and pi's tools. The environment the executor sets is read by
// bind.ts's fromEnvironment.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { bindActor, fromEnvironment, type Bound } from "./bind.js";
import type { Agent, Checks } from "./actor.js";
import { Guard, type TestsDeclaration } from "./guard.js";

/** What the role's specialists declared a test to be (ADR-044), beside
 *  the loop in the directory pi reads; absent or empty means no guard. */
function testsDeclaration(): TestsDeclaration {
  const dir = process.env["PI_CODING_AGENT_DIR"];
  if (!dir) return { files: [], source: [], command: [] };
  try {
    const parsed = JSON.parse(readFileSync(join(dir, "tests.json"), "utf8")) as Partial<TestsDeclaration>;
    return { files: parsed.files ?? [], source: parsed.source ?? [], command: parsed.command ?? [] };
  } catch {
    return { files: [], source: [], command: [] };
  }
}

export default function fabriek(pi: ExtensionAPI): void {
  const world = fromEnvironment();
  let context: ExtensionContext | undefined;
  let bound: Bound | undefined;
  let guard: Guard | undefined;
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
    guard = new Guard(testsDeclaration(), ctx.cwd);
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

  /** The test-first guard (ADR-044): an edit of production code is refused
   *  by the order of what the loop saw, and the refusal is the tool's
   *  result and an event. A bash call whose words are a declared runner is
   *  remembered so its result can be the run's verdict. */
  const runs = new Set<string>();
  pi.on("tool_call", async (event) => {
    if (!guard) return;
    const input = event.input as { path?: string; command?: string };
    if ((event.toolName === "write" || event.toolName === "edit") && typeof input.path === "string") {
      const refusal = guard.edit(input.path);
      if (refusal) {
        await actor()?.publish("guard_refused", { rule: refusal.rule, tool: event.toolName, path: input.path });
        return { block: true, reason: refusal.reason };
      }
    }
    if (event.toolName === "bash" && typeof input.command === "string" && guard.isTestRun(input.command)) {
      runs.add(event.toolCallId);
    }
    return undefined;
  });
  pi.on("tool_result", async (event) => {
    if (!guard || !runs.delete(event.toolCallId)) return;
    guard.ran(!event.isError);
  });

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
      const refusal = guard?.outcome(params.status) ?? null;
      if (refusal) {
        await actor()?.publish("guard_refused", { rule: refusal.rule, tool: "report_outcome", status: params.status });
        return { content: [{ type: "text", text: refusal.reason }], details: {}, isError: true };
      }
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
