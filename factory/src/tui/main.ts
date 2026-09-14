// The operator's one face (ADR-039 point 3), on the operator's host. Reads
// the relay through `fabriek -f FACTORY watch`, folds every line into the
// model, draws the view, and writes through the CLI: every key here is a
// fabriek command, so every intervention passes the executor and is
// recorded. Nothing here reaches the machine any other way.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fold, initial, type State } from "./model.js";
import { render } from "./view.js";
import { keepWatching } from "./watch.js";
import { cliArgs, watchArgs } from "./cli.js";
import { parseLine } from "../relay/format.js";

const ESC = String.fromCharCode(27);
const CLEAR = `${ESC}[2J${ESC}[H`;

const factory: string = process.argv[2] ?? "";
if (!factory) {
  process.stderr.write("usage: fabriek-tui <factory> [role ...]\n");
  process.exit(1);
}
const roles = process.argv.slice(3);
let state: State = initial(roles);
let draw = true;

const cli = process.env["FABRIEK_CLI"] ?? "fabriek";

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
      if (title && workflow) notice = await run(cliArgs(factory, "file", [...(body ? ["-m", body] : []), workflow, title]));
      break;
    }
    case "s": {
      const role = await ask("steer which role:");
      const text = await ask("say:");
      if (role && text) notice = await run(cliArgs(factory, "steer", [role, text]));
      break;
    }
    case "x": {
      const role = await ask("stop which role:");
      if (role) notice = await run(cliArgs(factory, "stop", [role]));
      break;
    }
    case "r": {
      const issue = await ask("retry which issue:");
      if (issue) notice = await run(cliArgs(factory, "send", [JSON.stringify({ verb: "retry", issue: Number(issue) })]));
      break;
    }
    case "b": {
      const issue = await ask("block which issue:");
      const on = await ask("on which issue:");
      if (issue && on) notice = await run(cliArgs(factory, "send", [JSON.stringify({ verb: "block", issue: Number(issue), on: Number(on) })]));
      break;
    }
    case "p": {
      const role = await ask("push which role's branch:");
      if (role) notice = await run(cliArgs(factory, "send", [JSON.stringify({ verb: "push", role })]));
      break;
    }
    case "m":
      notice = await run(cliArgs(factory, "mirror", []));
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

keepWatching({
  spawn: () => spawn(cli, watchArgs(factory), { stdio: ["ignore", "pipe", "inherit"] }),
  onStart: () => {
    state = initial(roles);
  },
  onLine: (line) => {
    state = fold(state, parseLine(line));
  },
  onEnd: (code) => {
    notice = `watch ended with ${code}; starting it again`;
    paint();
  },
  pause: () => new Promise((r) => setTimeout(r, 2000)),
});

process.stdin.setRawMode?.(true);
process.stdin.resume();
process.stdin.setEncoding("utf8");
process.stdin.on("data", (k: string) => void key(k));
setInterval(paint, 500);
paint();
