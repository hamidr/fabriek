// One screen (ADR-039 point 3): the roles and what each is doing, the board
// by stage, the last findings and commands, the spend, and the keys. A pure
// function of the model and the terminal's size, cut to width.
import type { State } from "./model.js";

export interface Screen {
  columns: number;
  rows: number;
  factory: string;
}

const KEYS = "f file  s steer  x stop  r retry  b block  p push  m mirror  q quit";

function fit(line: string, width: number): string {
  return line.length > width ? line.slice(0, Math.max(0, width - 1)) + "~" : line;
}

export function render(s: State, screen: Screen): string {
  const w = Math.max(20, screen.columns);
  const lines: string[] = [];
  lines.push(
    `fabriek  ${screen.factory}  ${s.routing ? "routing on" : "routing stopped at the soft limit"}  spend ${s.spend["total"] ?? 0} (decider ${s.spend["decider"] ?? 0})`,
  );
  lines.push("");
  lines.push("roles");
  for (const [name, r] of Object.entries(s.roles)) {
    const where = r.issue !== undefined && r.state !== "idle" ? ` #${r.issue}` : "";
    lines.push(`  ${name.padEnd(14)}${(r.state + where).padEnd(16)}${String(s.spend[name] ?? 0).padStart(7)}  ${r.last}`);
  }
  lines.push("");
  lines.push("board");
  const stages = [...new Set(s.board.map((i) => i.stage ?? "none"))];
  if (stages.length === 0) lines.push("  (nothing open)");
  for (const stage of stages) {
    lines.push(`  ${stage}`);
    for (const i of s.board.filter((x) => (x.stage ?? "none") === stage)) {
      lines.push(`    #${i.number} ${i.title}${i.assignee ? ` (${i.assignee})` : ""}${i.blocked ? " blocked" : ""}`);
    }
  }
  lines.push("");
  lines.push("commands");
  for (const c of s.commands.slice(-5)) lines.push(`  ${c.by}: ${c.text}`);
  lines.push("");
  lines.push("findings");
  for (const f of s.findings.slice(-5)) lines.push(`  ${f.role}: ${f.text}`);
  lines.push("");
  lines.push("probes");
  for (const p of s.probes.slice(-3)) lines.push(`  ${p}`);
  lines.push("");
  // The keys are the last row whatever the height; what is cut is above them.
  const rows = Math.max(2, screen.rows);
  const cut = lines.map((l) => fit(l, w)).slice(0, rows - 1);
  while (cut.length < rows - 1) cut.push("");
  cut.push(fit(KEYS, w));
  return cut.join("\n");
}
