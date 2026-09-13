// The scripted decider's whole judgement: a task at a stage with nobody on
// it goes to a ready role that provides the stage, one task per role per
// round. Nothing is retried, blocked, filed, pushed or stopped by it; those
// are the operator's to send while the model is out of the picture.
import type { Command } from "../vocabulary.js";
import { capableRoles, type Declaration } from "../declaration.js";
import type { Snapshot } from "../decider/core.js";

export function decide(s: Snapshot, d: Declaration): Command[] {
  if (!s.routing) return [];
  const free = new Set(s.ready);
  const out: Command[] = [];
  for (const i of s.issues) {
    if (!i.stage || i.assignee || i.blocked || i.attempts >= d.resources.taskAttempts) continue;
    const role = capableRoles(d, i.stage).find((r) => free.has(r));
    if (!role) continue;
    free.delete(role);
    out.push({ verb: "assign", issue: i.number, role });
  }
  return out;
}
