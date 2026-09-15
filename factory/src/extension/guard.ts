// The test-first guard (ADR-044): what the agent may do next, from what the
// loop has seen. Pure: paths and argv words in, a refusal or nothing out.
// The loop calls edit() before a write or an edit runs, ran() when a test
// run's result arrives, outcome() before an outcome is recorded. The same
// machine is models/tdd-guard.qnt, checked there before it was written here.

/** What a specialist declared, unioned for the role: tests.json. */
export interface TestsDeclaration {
  files: string[];
  source: string[];
  command: string[];
}

export type Kind = "test" | "source" | "free";
export type Verdict = "none" | "failed" | "passed";
export type Rule = "run-before-code" | "see-it-fail-first" | "run-between-steps" | "done-is-green";

export interface Refusal {
  rule: Rule;
  reason: string;
}

/** A glob over a relative path: ** any depth, * within a segment, ? one char. */
function globToRegExp(glob: string): RegExp {
  let out = "^";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      const slash = glob[i + 2] === "/";
      out += slash ? "(?:.*/)?" : ".*";
      i += slash ? 2 : 1;
    } else if (c === "*") out += "[^/]*";
    else if (c === "?") out += "[^/]";
    else if (c !== undefined && /[.+^${}()|[\]\\]/.test(c)) out += `\\${c}`;
    else out += c;
  }
  return new RegExp(`${out}$`);
}

export class Guard {
  private lastRun: Verdict = "none";
  private sourceEditsSinceRun = 0;
  private testEditedSinceRun = false;
  private readonly tests: RegExp[];
  private readonly source: RegExp[];
  private readonly commands: string[][];

  constructor(
    declaration: TestsDeclaration,
    private readonly cwd: string,
  ) {
    this.tests = declaration.files.map(globToRegExp);
    this.source = declaration.source.map(globToRegExp);
    this.commands = declaration.command.map((c) => c.trim().split(/\s+/).filter(Boolean));
  }

  /** Nothing to watch means nothing to refuse. */
  get active(): boolean {
    return this.source.length > 0;
  }

  classify(path: string): Kind {
    const rel = path.startsWith(`${this.cwd}/`) ? path.slice(this.cwd.length + 1) : path.replace(/^\.\//, "");
    if (this.tests.some((re) => re.test(rel))) return "test";
    if (this.source.some((re) => re.test(rel))) return "source";
    return "free";
  }

  /** A run is any command segment whose first words, after the environment
   *  assignments a shell allows in front of a command, are a declared runner. */
  isTestRun(command: string): boolean {
    return command
      .split(/&&|\|\||;|\||\n/)
      .map((segment) => segment.trim().split(/\s+/).filter(Boolean))
      .map((words) => {
        let i = 0;
        while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i] ?? "")) i++;
        return words.slice(i);
      })
      .some((words) => this.commands.some((runner) => runner.every((w, i) => words[i] === w)));
  }

  /** Before a write or an edit: a refusal, or null and the machine moves. */
  edit(path: string): Refusal | null {
    if (!this.active) return null;
    const kind = this.classify(path);
    if (kind === "free") return null;
    if (kind === "test") {
      this.testEditedSinceRun = true;
      return null;
    }
    if (this.lastRun === "none") {
      return refuse("run-before-code", `${path} is production code and no test has run this session; write or pick the test for this behaviour and run the tests first, so the change starts from a failing test.`);
    }
    if (this.testEditedSinceRun) {
      return refuse("see-it-fail-first", `a test file changed since the last run; run the tests and see the new test fail before editing ${path}.`);
    }
    if (this.lastRun === "passed" && this.sourceEditsSinceRun >= 1) {
      return refuse("run-between-steps", `the tests passed and ${this.sourceEditsSinceRun} production edit already followed; run the tests before the next edit, so every step is checked.`);
    }
    this.sourceEditsSinceRun += 1;
    return null;
  }

  /** A test run the loop saw, with its verdict. */
  ran(passed: boolean): void {
    this.lastRun = passed ? "passed" : "failed";
    this.sourceEditsSinceRun = 0;
    this.testEditedSinceRun = false;
  }

  /** Before an outcome is recorded: done needs green after the last edit. */
  outcome(status: "done" | "blocked" | "failed"): Refusal | null {
    if (!this.active || status !== "done") return null;
    if (this.lastRun !== "passed") {
      return refuse("done-is-green", `done needs a passing test run; the last run ${this.lastRun === "none" ? "has not happened" : "failed"}. Run the tests, or report blocked or failed with what you saw.`);
    }
    if (this.sourceEditsSinceRun > 0 || this.testEditedSinceRun) {
      return refuse("done-is-green", "files changed after the last passing test run; run the tests again before reporting done.");
    }
    return null;
  }
}

function refuse(rule: Rule, reason: string): Refusal {
  return { rule, reason: `test-first guard (${rule}): ${reason}` };
}
