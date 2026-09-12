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
  lines.push(`cageworks  ${screen.factory}  ${s.routing ? "routing on" : "routing stopped at the soft limit"}  spend ${s.spend["total"] ?? 0}`);
  lines.push("");
  lines.push("roles");
  for (const [name, r] of Object.entries(s.roles)) {
    const where = r.issue !== undefined && r.state !== "idle" ? ` #${r.issue}` : "";
    lines.push(`  ${name.padEnd(14)}${(r.state + where).padEnd(16)}${r.last}`);
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
  lines.push(KEYS);
  const cut = lines.map((l) => fit(l, w));
  return cut.slice(0, Math.max(1, screen.rows)).join("\n");
}
