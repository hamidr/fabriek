// The decider as the pi extension that runs in its own cage (ADR-034 point
// 1). This file binds pi to the decider and holds nothing of its own: the
// board, the ready set, the commands stream and the tick are decider/bind.ts,
// and what is here is pi as the judge and pi's tools, each of which goes
// through the core's gate and then to the commands stream, where the
// executor validates it again against the board and acts or refuses.
//
// Environment, as for a role's session, plus:
//   FABRIEK_HOME_HOST   this cage's home as the machine sees it, so a file
//                         command can name files the executor can open
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { mkdirSync, writeFileSync } from "node:fs";
import { bindDecider, fromEnvironment, type BoundDecider } from "./bind.js";

export default function decider(pi: ExtensionAPI): void {
  const world = fromEnvironment();
  const homeInside = process.env["HOME"] ?? "/root";
  const homeHost = process.env["FABRIEK_HOME_HOST"] ?? homeInside;

  let context: ExtensionContext | undefined;
  let bound: BoundDecider | undefined;
  const core = () => {
    if (!bound) throw new Error("the decider has not started");
    return bound.core;
  };

  pi.on("session_start", async (_event, ctx) => {
    context = ctx;
    bound = bindDecider({
      ...world,
      async think(prompt) {
        // A model still on the last prompt is not given the next; the tick brings it back.
        if (context?.isIdle()) pi.sendUserMessage(prompt);
      },
    });
    await bound.start();
  });

  pi.on("session_shutdown", async () => {
    bound?.stop();
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
    async execute(_id, p) { return result(await core().command({ verb: "assign", ...p })); },
  });
  pi.registerTool({
    name: "retry",
    label: "Retry",
    description: "Send a failed issue back to the role that had it, with its previous outcome.",
    parameters: Type.Object({ issue: Type.Integer() }),
    async execute(_id, p) { return result(await core().command({ verb: "retry", ...p })); },
  });
  pi.registerTool({
    name: "block",
    label: "Block",
    description: "Mark an issue as waiting on another.",
    parameters: Type.Object({ issue: Type.Integer(), on: Type.Integer() }),
    async execute(_id, p) { return result(await core().command({ verb: "block", ...p })); },
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
      return result(await core().command({ verb: "file", titleFile: `${homeHost}/${dir}/title`, bodyFile: `${homeHost}/${dir}/body`, stage: p.stage }));
    },
  });
  pi.registerTool({
    name: "push",
    label: "Push",
    description: "Push a role's branch to the forge and open its pull request.",
    parameters: Type.Object({ role: Type.String() }),
    async execute(_id, p) { return result(await core().command({ verb: "push", ...p })); },
  });
  pi.registerTool({
    name: "stop",
    label: "Stop",
    description: "End a role's running turn. Its task stays with it.",
    parameters: Type.Object({ role: Type.String() }),
    async execute(_id, p) { return result(await core().command({ verb: "stop", ...p })); },
  });
  pi.registerTool({
    name: "wait",
    label: "Wait",
    description: "Nothing should happen now. Say why in one line.",
    parameters: Type.Object({ why: Type.String() }),
    async execute(_id, p) { return { content: [{ type: "text" as const, text: `waiting: ${p.why}` }], details: {} }; },
  });
}
