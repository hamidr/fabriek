// The executor (ADR-034): the one thing that acts, and it decides nothing.
// Every verb is validated against the declaration and the board before it
// touches anything; the board is written before work is sent and confirmed
// only on the ack (ADR-033 point 4); an outcome is judged by what is
// checkable and nothing else (ADR-034 point 4). Written against five
// interfaces, so the protocol is one thing and the machine another.
import type { Command } from "../vocabulary.js";
import type { Message } from "../messages.js";
import { capableRoles, stageOf, type Declaration } from "../declaration.js";
import { isRoleName } from "../names.js";

export interface BoardIssue {
  number: number;
  title: string;
  body: string;
  state: "open" | "closed";
  labels: string[];
  assignee: string | null;
  thread: { by: string; body: string }[];
}

export interface Board {
  open(): Promise<BoardIssue[]>;
  issue(n: number): Promise<BoardIssue>;
  create(title: string, body: string, stage: string): Promise<number>;
  setLabels(n: number, labels: string[]): Promise<void>;
  assign(n: number, role: string | null): Promise<void>;
  comment(n: number, body: string): Promise<void>;
  close(n: number): Promise<void>;
  openPullRequest(branch: string, title: string): Promise<number>;
}

export interface Bus {
  send(role: string, message: Message): Promise<void>;
}

export interface Sessions {
  start(role: string): Promise<void>;
  stop(role: string): Promise<void>;
  running(): Set<string>;
}

export interface Git {
  /** Commits on the role's branch that are not on the base. */
  commitsAhead(branch: string): Promise<number>;
  push(branch: string): Promise<void>;
  /** main and refs/cageworks/record to origin, together. */
  mirror(): Promise<void>;
}

export interface Spend {
  total(): Promise<number>;
}

export interface Files {
  readFile(path: string): Promise<string>;
}

export interface ExecutorOptions {
  declaration: Declaration;
  workflow: string;
  board: Board;
  bus: Bus;
  sessions: Sessions;
  git: Git;
  spend: Spend;
  reconcileTimeoutMs?: number;
  /** Fraction of the ceiling at which routing stops (ADR-037 point 4). */
  softFraction?: number;
}

export type Result = { ok: true } | { ok: false; reason: string };

const ASSIGNING = "assigning";
const ASSIGNED = "assigned";
const BLOCKED = "blocked";
const STATE_LABELS = new Set([ASSIGNING, ASSIGNED, BLOCKED, "memory"]);

const refuse = (reason: string): Result => ({ ok: false, reason });

/** The branch a role's work is on: its own namespace (ADR-010). */
export function workBranch(role: string): string {
  return `${role}/work`;
}

export class Executor {
  private readonly ready = new Set<string>();
  private readonly acks: number[] = [];
  private readonly heldAnswers = new Map<string, number[]>();
  private readonly timeoutMs: number;
  private readonly softFraction: number;
  private routingOn = true;

  constructor(private readonly o: ExecutorOptions) {
    this.timeoutMs = o.reconcileTimeoutMs ?? 5000;
    this.softFraction = o.softFraction ?? 0.9;
  }

  /** Something an actor said on its control stream. Every one is a claim. */
  heard(role: string, m: Message): void {
    switch (m.kind) {
      case "ready":
        this.ready.add(role);
        return;
      case "ack":
        this.acks.push(m.issue);
        return;
      case "held":
        this.heldAnswers.set(role, m.issues);
        return;
      default:
        return;
    }
  }

  routing(): boolean {
    return this.routingOn;
  }

  /** Move acked rows from assigning to assigned. Called after heard(). */
  async settle(): Promise<void> {
    for (const issue of this.acks.splice(0)) {
      const i = await this.o.board.issue(issue);
      if (!i.labels.includes(ASSIGNING)) continue;
      await this.o.board.setLabels(issue, swap(i.labels, ASSIGNING, ASSIGNED));
    }
  }

  /** On start: ask every actor with an assigning row what it holds, and
   *  resolve those rows from the answers, never creating one (ADR-033). */
  async reconcile(): Promise<void> {
    const pending = (await this.o.board.open()).filter((i) => i.labels.includes(ASSIGNING) && i.assignee);
    const roles = new Set(pending.map((i) => i.assignee as string));
    for (const role of roles) await this.o.bus.send(role, { kind: "reconcile" });
    await new Promise((r) => setTimeout(r, this.timeoutMs));
    for (const i of pending) {
      const role = i.assignee as string;
      const answer = this.heldAnswers.get(role);
      if (answer === undefined) continue; // unknown, not free: the row stays
      if (answer.includes(i.number)) {
        await this.o.board.setLabels(i.number, swap(i.labels, ASSIGNING, ASSIGNED));
      } else {
        await this.o.board.setLabels(i.number, i.labels.filter((l) => l !== ASSIGNING));
        await this.o.board.assign(i.number, null);
      }
    }
    this.heldAnswers.clear();
  }

  /** One verb, validated then acted on, or refused with the reason. */
  async apply(c: Command, files?: Files): Promise<Result> {
    switch (c.verb) {
      case "file":
        return this.file(c.titleFile, c.bodyFile, c.stage, files);
      case "assign":
        return this.assign(c.issue, c.role);
      case "retry":
        return this.retry(c.issue);
      case "block":
        return this.block(c.issue, c.on);
      case "push":
        return this.push(c.role);
      case "stop":
        return this.stop(c.role);
    }
  }

  private async file(titleFile: string, bodyFile: string, stage: string, files?: Files): Promise<Result> {
    if (!stageOf(this.o.declaration, this.o.workflow, stage)) return refuse(`workflow ${this.o.workflow} has no stage ${stage}`);
    if (!files) return refuse("file needs a way to read files");
    const title = (await files.readFile(titleFile)).trim();
    const body = await files.readFile(bodyFile);
    if (!title) return refuse("the title file is empty");
    await this.o.board.create(title, body, stage);
    return { ok: true };
  }

  private stageLabel(i: BoardIssue): string | null {
    return i.labels.find((l) => !STATE_LABELS.has(l)) ?? null;
  }

  private attemptsOf(i: BoardIssue): number {
    return i.thread.filter((c) => c.by === "executor" && /^attempt \d+ started/.test(c.body)).length;
  }

  private async holds(role: string): Promise<boolean> {
    return (await this.o.board.open()).some((i) => i.assignee === role && (i.labels.includes(ASSIGNING) || i.labels.includes(ASSIGNED)));
  }

  private async assign(issue: number, role: string): Promise<Result> {
    if (!(role in this.o.declaration.roles)) return refuse(`no role ${role} is declared`);
    let i: BoardIssue;
    try {
      i = await this.o.board.issue(issue);
    } catch {
      return refuse(`no issue ${issue}`);
    }
    const stage = this.stageLabel(i);
    if (!stage || i.state !== "open") return refuse(`issue ${issue} is not at a stage`);
    if (!capableRoles(this.o.declaration, stage).includes(role)) return refuse(`role ${role} does not provide ${stage}`);
    if (await this.holds(role)) return refuse(`role ${role} holds work already`);
    if (!this.ready.has(role)) return refuse(`role ${role} is not ready`);
    const attempts = this.attemptsOf(i);
    if (attempts >= this.o.declaration.resources.taskAttempts) return refuse(`issue ${issue} has used its ${attempts} attempts`);
    if (!(await this.mayRoute())) return refuse("the soft limit is reached; nothing new is routed");

    const attempt = attempts + 1;
    const previous = [...i.thread].reverse().find((c) => c.by === i.assignee && c.body.startsWith("outcome:"));
    let brief = `attempt ${attempt} started for ${role}`;
    if (attempt > 1 && previous) brief += `\n\nprevious outcome:\n${previous.body}`;
    await this.o.board.assign(issue, role);
    await this.o.board.setLabels(issue, [...i.labels.filter((l) => l !== ASSIGNED && l !== BLOCKED), ASSIGNING]);
    await this.o.board.comment(issue, brief);
    this.ready.delete(role);
    await this.o.bus.send(role, { kind: "assignment", issue, attempt });
    return { ok: true };
  }

  private async retry(issue: number): Promise<Result> {
    let i: BoardIssue;
    try {
      i = await this.o.board.issue(issue);
    } catch {
      return refuse(`no issue ${issue}`);
    }
    if (!i.assignee) return refuse(`issue ${issue} has had no role to go back to`);
    return this.assign(issue, i.assignee);
  }

  private async block(issue: number, on: number): Promise<Result> {
    let i: BoardIssue;
    try {
      i = await this.o.board.issue(issue);
      await this.o.board.issue(on);
    } catch {
      return refuse(`no such issue: ${issue} or ${on}`);
    }
    if (!i.labels.includes(BLOCKED)) await this.o.board.setLabels(issue, [...i.labels, BLOCKED]);
    await this.o.board.comment(issue, `blocked on #${on}`);
    return { ok: true };
  }

  private async push(role: string): Promise<Result> {
    if (!isRoleName(role) || !(role in this.o.declaration.roles)) return refuse(`no role ${role} is declared`);
    const branch = workBranch(role);
    await this.o.git.push(branch);
    await this.o.board.openPullRequest(branch, branch);
    return { ok: true };
  }

  private async stop(role: string): Promise<Result> {
    if (!(role in this.o.declaration.roles)) return refuse(`no role ${role} is declared`);
    await this.o.bus.send(role, { kind: "abort" });
    return { ok: true };
  }

  /** The soft limit (ADR-037 point 4): below it work is routed, at it nothing new is. */
  private async mayRoute(): Promise<boolean> {
    const ceiling = this.o.declaration.resources.tokens;
    if (!ceiling) return true;
    const total = await this.o.spend.total();
    this.routingOn = total < ceiling * this.softFraction;
    return this.routingOn;
  }

  /** Read outcomes off the board and move what is checkable (ADR-034 point 4). */
  async checkOutcomes(): Promise<void> {
    for (const i of await this.o.board.open()) {
      if (!i.labels.includes(ASSIGNED) || !i.assignee) continue;
      const started = i.thread.map((c, k) => ({ c, k })).filter(({ c }) => c.by === "executor" && /^attempt \d+ started/.test(c.body)).at(-1);
      const outcome = i.thread
        .map((c, k) => ({ c, k }))
        .filter(({ c, k }) => c.by === i.assignee && c.body.startsWith("outcome:") && k > (started?.k ?? -1))
        .at(-1);
      if (!outcome) continue;
      const status = outcome.c.body.split("\n")[0]?.replace(/^outcome:\s*/, "").trim();
      const stage = this.stageLabel(i);
      const bare = i.labels.filter((l) => !STATE_LABELS.has(l));
      switch (status) {
        case "done": {
          if ((await this.o.git.commitsAhead(workBranch(i.assignee))) === 0) {
            await this.o.board.comment(i.number, "not done: no commit on the role's branch for this task");
            await this.o.board.setLabels(i.number, bare);
            await this.o.board.assign(i.number, null);
            break;
          }
          const at = stage ? stageOf(this.o.declaration, this.o.workflow, stage) : null;
          await this.o.board.assign(i.number, null);
          if (at?.next) {
            await this.o.board.setLabels(i.number, [at.next]);
          } else {
            await this.o.board.setLabels(i.number, bare);
            await this.o.board.close(i.number);
          }
          break;
        }
        case "blocked":
          await this.o.board.setLabels(i.number, [...new Set([...i.labels, BLOCKED])]);
          break;
        default:
          await this.o.board.setLabels(i.number, bare);
          break;
      }
    }
  }

  async mirror(): Promise<void> {
    await this.o.git.mirror();
  }

  /** The board as the operator sees it, published for the relay (ADR-039). */
  async snapshot(): Promise<{ issues: unknown[]; ready: string[]; routing: boolean }> {
    const issues = (await this.o.board.open()).map((i) => ({
      number: i.number,
      title: i.title,
      stage: this.stageLabel(i),
      assignee: i.assignee,
      blocked: i.labels.includes(BLOCKED),
      attempts: this.attemptsOf(i),
    }));
    return { issues, ready: [...this.ready], routing: this.routingOn };
  }
}

function swap(labels: string[], from: string, to: string): string[] {
  return [...new Set(labels.map((l) => (l === from ? to : l)))];
}
