// A decider with no model behind it: the same binding as the pi extension
// (decider/bind.ts), judging by policy.ts where pi would think. Every ask
// still goes through the core's gate and then the executor's, so what the
// system harness exercises is the factory's routing and not a shortcut.
import { bindDecider, fromEnvironment } from "../decider/bind.js";
import { decide } from "./policy.js";

const world = fromEnvironment();
const bound = bindDecider({
  ...world,
  tickMs: Number(process.env["CAGEWORKS_FAKE_TICK_MS"] ?? "2000"),
  async think(_prompt, snapshot) {
    for (const c of decide(snapshot, world.declaration)) {
      const r = await bound.core.command(c);
      if (!r.ok) process.stderr.write(`fake decider: ${c.verb} refused: ${r.reason}\n`);
    }
  },
});

bound.start().catch((e) => {
  process.stderr.write(`fake decider: ${String(e)}\n`);
  process.exit(1);
});
process.on("SIGTERM", () => {
  bound.stop();
  process.exit(0);
});
