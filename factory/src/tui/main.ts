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
/** The role the operator has picked: its stream on screen, s and x aimed at it. */
let selected = 0;
const selectedRole = (): string | undefined => Object.keys(state.roles)[selected];

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

/**
 * One line of input from the operator, with the screen given back after.
 * The hotkeys are off for the prompt's duration: readline reads the same
 * stdin, and with both listening every letter of an answer was a key, so
 * typing a role called "reviewer" ran retry, file and steer on the way.
 */
function ask(question: string): Promise<string> {
  return new Promise((resolve) => {
    draw = false;
    process.stdin.off("data", onKey);
    process.stdin.setRawMode?.(false);
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question(`\n${question} `, (answer) => {
      rl.close();
      process.stdin.setRawMode?.(true);
      process.stdin.on("data", onKey);
      process.stdin.resume();
      draw = true;
      resolve(answer.trim());
    });
  });
}

let notice = "";
const onKey = (k: string): void => void key(k);
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
    case "j":
    case `${ESC}[B`:
      selected = Math.min(selected + 1, Math.max(0, Object.keys(state.roles).length - 1));
      break;
    case "k":
    case `${ESC}[A`:
      selected = Math.max(0, selected - 1);
      break;
    case "s": {
      const role = selectedRole();
      if (!role) break;
      const text = await ask(`steer ${role}:`);
      if (text) notice = await run(cliArgs(factory, "steer", [role, text]));
      break;
    }
    case "x": {
      const role = selectedRole();
      if (!role) break;
      const sure = await ask(`stop ${role}'s turn? [y/N]`);
      if (sure.toLowerCase() === "y") notice = await run(cliArgs(factory, "stop", [role]));
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
      const role = selectedRole();
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
  const screen = {
    columns: process.stdout.columns || 80,
    rows: process.stdout.rows || 24,
    factory,
    selected: selectedRole(),
    notice,
    color: process.stdout.isTTY === true && process.env["NO_COLOR"] === undefined,
  };
  process.stdout.write(CLEAR + render(state, screen));
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
process.stdin.on("data", onKey);
setInterval(paint, 500);
paint();
