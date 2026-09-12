// The operator's one face (ADR-039 point 3), on the operator's host. Reads
// the relay through `cageworks factory watch`, folds every line into the
// model, draws the view, and writes through the CLI: every key here is a
// cageworks command, so every intervention passes the executor and is
// recorded. Nothing here reaches the machine any other way.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fold, initial, type State } from "./model.js";
import { render } from "./view.js";
import { parseLine } from "../relay/format.js";

const ESC = String.fromCharCode(27);
const CLEAR = `${ESC}[2J${ESC}[H`;

const factory: string = process.argv[2] ?? "";
if (!factory) {
  process.stderr.write("usage: cageworks-tui <factory> [role ...]\n");
  process.exit(1);
}
const roles = process.argv.slice(3);
let state: State = initial(roles);
let draw = true;

const cli = process.env["CAGEWORKS_CLI"] ?? "cageworks";

function run(args: string[]): Promise<string> {
  return new Promise((resolve) => {
    const child = spawn(cli, args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    child.stdout.on("data", (c) => (out += c));
    child.stderr.on("data", (c) => (out += c));
    child.on("exit", () => resolve(out.trim()));
  });
}

/** One line of input from the operator, with the screen given back after. */
function ask(question: string): Promise<string> {
  return new Promise((resolve) => {
    draw = false;
    process.stdin.setRawMode?.(false);
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question(`\n${question} `, (answer) => {
      rl.close();
      process.stdin.setRawMode?.(true);
      process.stdin.resume();
      draw = true;
      resolve(answer.trim());
    });
  });
}

let notice = "";
async function key(k: string): Promise<void> {
  switch (k) {
    case "q":
    case "\u0003":
      process.stdout.write(CLEAR);
      process.exit(0);
      break;
    case "f": {
      const title = await ask("title:");
      const body = await ask("body:");
      const workflow = await ask("workflow:");
      if (title && workflow) notice = await run(["task", "file", factory, workflow, title, body]);
      break;
    }
    case "s": {
      const role = await ask("steer which role:");
      const text = await ask("say:");
      if (role && text) notice = await run(["role", "steer", factory, role, text]);
      break;
    }
    case "x": {
      const role = await ask("stop which role:");
      if (role) notice = await run(["role", "stop", factory, role]);
      break;
    }
    case "r": {
      const issue = await ask("retry which issue:");
      if (issue) notice = await run(["factory", "send", factory, JSON.stringify({ verb: "retry", issue: Number(issue) })]);
      break;
    }
    case "b": {
      const issue = await ask("block which issue:");
      const on = await ask("on which issue:");
      if (issue && on) notice = await run(["factory", "send", factory, JSON.stringify({ verb: "block", issue: Number(issue), on: Number(on) })]);
      break;
    }
    case "p": {
      const role = await ask("push which role's branch:");
      if (role) notice = await run(["factory", "send", factory, JSON.stringify({ verb: "push", role })]);
      break;
    }
    case "m":
      notice = await run(["factory", "mirror", factory]);
      break;
    default:
      break;
  }
}

function paint(): void {
  if (!draw) return;
  const screen = { columns: process.stdout.columns || 80, rows: (process.stdout.rows || 24) - 1, factory };
  process.stdout.write(CLEAR + render(state, screen) + (notice ? `\n${notice}` : ""));
}

const watch = spawn(cli, ["factory", "watch", factory], { stdio: ["ignore", "pipe", "inherit"] });
const lines = createInterface({ input: watch.stdout });
lines.on("line", (line) => {
  try {
    state = fold(state, parseLine(line));
  } catch {
    // a line that is not the relay's is the relay's problem to say
  }
});
watch.on("exit", (code) => {
  notice = `watch ended with ${code}`;
  paint();
});

process.stdin.setRawMode?.(true);
process.stdin.resume();
process.stdin.setEncoding("utf8");
process.stdin.on("data", (k: string) => void key(k));
setInterval(paint, 500);
paint();
