// One screen (ADR-039 point 3), in panes: the roles with one selected, the
// board by stage, what the factory did last, and the selected role's own
// stream, with the keys on the last row. A pure function of the model and
// the screen: colour is a flag, so a test reads plain text, and width is
// counted without the colour codes, so a coloured line fits like a plain
// one.
import type { Activity, State } from "./model.js";

export interface Screen {
  columns: number;
  rows: number;
  factory: string;
  /** The role whose stream is shown and whom s and x act on. */
  selected?: string | undefined;
  /** The last command's answer, beside the keys. */
  notice?: string | undefined;
  color?: boolean;
  /** Show the stream's lines whole, over several rows, rather than cut. */
  wrap?: boolean;
}

const KEYS = "j/k role  w wrap  s steer  x stop  f file  r retry  b block  p push  m mirror  q quit";

/** Box glyphs, by code point so the source stays ASCII. */
const G = {
  h: String.fromCharCode(0x2500),
  v: String.fromCharCode(0x2502),
  tl: String.fromCharCode(0x250c),
  tr: String.fromCharCode(0x2510),
  bl: String.fromCharCode(0x2514),
  br: String.fromCharCode(0x2518),
};

const ESC = String.fromCharCode(27);
const paint = (on: boolean) => (code: string, text: string) => (on ? `${ESC}[${code}m${text}${ESC}[0m` : text);

/** A figure the eye reads at once: 1.4M, 7.0k, 0. */
export function short(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

const SGR = new RegExp(`${ESC}\\[[0-9;]*m`, "g");

/** Columns a line takes on screen: colour codes take none. */
function width(text: string): number {
  return [...text.replace(SGR, "")].length;
}

/** A line at exactly w columns: padded, or cut with a mark, colour kept whole. */
function fit(line: string, w: number): string {
  const seen = width(line);
  if (seen <= w) return line + " ".repeat(w - seen);
  let out = "";
  let cols = 0;
  for (const part of line.split(new RegExp(`(${ESC}\\[[0-9;]*m)`))) {
    if (part.startsWith(ESC)) {
      out += part;
      continue;
    }
    for (const ch of part) {
      if (cols >= w - 1) break;
      out += ch;
      cols++;
    }
  }
  // A cut inside a coloured span would leak its colour into the edge.
  return out + "~" + (line.includes(ESC) ? `${ESC}[0m` : "");
}

/** A pane: a title in its top edge, its lines cut to fit, newest kept when told. */
interface Pane {
  title: string;
  lines: string[];
  tail?: boolean;
  /** Lines wider than the pane go over several rows instead of being cut. */
  wrap?: boolean;
}

/** A line as rows of at most w columns, colour codes carried whole. */
function wrapLine(line: string, w: number): string[] {
  const rows: string[] = [];
  let row = "";
  let cols = 0;
  for (const part of line.split(new RegExp(`(${ESC}\\[[0-9;]*m)`))) {
    if (part.startsWith(ESC)) {
      row += part;
      continue;
    }
    for (const ch of part) {
      if (cols === w) {
        rows.push(row);
        row = "";
        cols = 0;
      }
      row += ch;
      cols++;
    }
  }
  rows.push(row);
  return rows;
}

function box(p: Pane, w: number, h: number, c: ReturnType<typeof paint>): string[] {
  const inner = Math.max(1, w - 2);
  const body = Math.max(0, h - 2);
  const lines = p.wrap ? p.lines.flatMap((l) => wrapLine(l, inner)) : p.lines;
  const shown = p.tail ? lines.slice(-body) : lines.slice(0, body);
  while (shown.length < body) shown.push("");
  const title = fit(` ${p.title} `, Math.min(inner, width(p.title) + 2));
  const top = G.tl + G.h + title + G.h.repeat(Math.max(0, inner - width(title) - 1)) + G.tr;
  const bottom = G.bl + G.h.repeat(inner) + G.br;
  const edge = c("2", G.v);
  return [c("2", top), ...shown.map((l) => `${edge}${fit(l, inner)}${edge}`), c("2", bottom)];
}

const STATE_COLOR: Record<string, string> = { idle: "32", working: "36", blocked: "31", unknown: "2" };

function rolesPane(s: State, selected: string | undefined, c: ReturnType<typeof paint>): Pane {
  const lines = Object.entries(s.roles).map(([name, r]) => {
    const where = r.issue !== undefined && r.state !== "idle" ? ` #${r.issue}` : "";
    // The guard's count comes first: the pane is narrow and the count is
    // what the operator acts on; a repeat is coloured as the fault it is.
    const guard = r.guard ? `guard ${r.guard.count}${r.guard.repeats >= 3 ? " repeat" : ""} ${r.guard.rule}` : "";
    const last = r.guard ? (r.guard.repeats >= 3 ? c("31", guard) : c("33", guard)) : r.last;
    const mark = name === selected ? ">" : " ";
    const state = c(STATE_COLOR[r.state] ?? "0", (r.state + where).padEnd(14));
    const text = `${mark} ${name.padEnd(12)}${state}${short(s.spend[name] ?? 0).padStart(7)}  ${last}`;
    return name === selected ? c("1", text) : text;
  });
  return { title: "roles", lines };
}

function boardPane(s: State, c: ReturnType<typeof paint>): Pane {
  const lines: string[] = [];
  const stages = [...new Set(s.board.map((i) => i.stage ?? "none"))];
  if (stages.length === 0) lines.push(c("2", "nothing open"));
  for (const stage of stages) {
    lines.push(c("1", stage));
    for (const i of s.board.filter((x) => (x.stage ?? "none") === stage)) {
      const who = i.assignee ? ` (${i.assignee})` : "";
      lines.push(`  #${i.number} ${i.title}${who}${i.blocked ? c("31", " blocked") : ""}`);
    }
  }
  return { title: "board", lines };
}

const BY_COLOR: Record<string, string> = { decider: "35", executor: "33", operator: "34" };

function activityLine(a: Activity, c: ReturnType<typeof paint>): string {
  return `${c(BY_COLOR[a.by] ?? "36", a.by.padEnd(10))}${a.text}`;
}

function activityPane(s: State, c: ReturnType<typeof paint>): Pane {
  return { title: "activity", lines: s.activity.map((a) => activityLine(a, c)), tail: true };
}

function streamPane(s: State, selected: string | undefined, wrap: boolean): Pane {
  const role = selected ?? Object.keys(s.roles)[0] ?? "";
  return { title: role || "stream", lines: s.stream[role] ?? [], tail: true, wrap };
}

/** Rows for panes stacked in one column: each its content, the rest to the
 *  last. The first pane is the roles, and every role stays on screen: what
 *  gives way is the tallest of the others. */
function stackHeights(panes: Pane[], rows: number, min = 3): number[] {
  const wanted = panes.map((p) => p.lines.length + 2);
  const heights = wanted.map((w) => Math.max(min, w));
  let over = heights.reduce((a, b) => a + b, 0) - rows;
  while (over > 0) {
    const rest = heights.slice(1);
    const i = rest.indexOf(Math.max(...rest)) + 1;
    if (heights[i]! <= min) break;
    heights[i]!--;
    over--;
  }
  const used = heights.reduce((a, b) => a + b, 0);
  if (used < rows) heights[heights.length - 1]! += rows - used;
  return heights;
}

function column(panes: Pane[], w: number, rows: number, c: ReturnType<typeof paint>): string[] {
  const heights = stackHeights(panes, rows);
  return panes.flatMap((p, i) => box(p, w, heights[i]!, c));
}

export function render(s: State, screen: Screen): string {
  const c = paint(screen.color === true);
  const w = Math.max(20, screen.columns);
  const rows = Math.max(4, screen.rows);
  const body = rows - 2;

  const routing = s.routing ? "routing on" : c("31", "routing stopped at the soft limit");
  const header = fit(` fabriek  ${screen.factory}  ${routing}  spend ${short(s.spend["total"] ?? 0)}  decider ${short(s.spend["decider"] ?? 0)}`, w);

  const left = [rolesPane(s, screen.selected, c), boardPane(s, c), activityPane(s, c)];
  const stream = streamPane(s, screen.selected, screen.wrap === true);

  let lines: string[];
  if (w >= 80) {
    const lw = Math.min(56, Math.floor(w / 2));
    const l = column(left, lw, body, c);
    const r = box(stream, w - lw, body, c);
    lines = l.map((line, i) => line + (r[i] ?? ""));
  } else {
    lines = column([...left, stream], w, body, c);
  }

  const keys = screen.notice ? `${KEYS}  ${c("33", screen.notice)}` : KEYS;
  return [c("7", header), ...lines.slice(0, body), fit(keys, w)].join("\n");
}
