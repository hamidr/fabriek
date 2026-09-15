// The actor (ADR-033): what a cage does between announcing ready and
// announcing ready again. Written against three interfaces, the bus it
// speaks on, the board it reads and writes, and the agent it drives, so the
// loop is one thing and pi is another (index.ts binds them).
//
// The actor writes nothing that the executor trusts: its ack and its held
// answer are claims (ADR-033 point 4), its checks are advice (ADR-035 point
// 5), and its outcome is a comment the executor reads and judges by what is
// checkable (ADR-034 point 4).
import type { Message } from "../messages.js";
import type { Comment, Issue } from "../forge/client.js";

export interface Bus {
  announce(message: Message): Promise<void>;
  ack(issue: number): Promise<void>;
  held(issues: number[]): Promise<void>;
  event(name: string, payload: unknown): Promise<void>;
  finding(text: string): Promise<void>;
}

export interface Board {
  issue(n: number): Promise<Issue>;
  thread(n: number): Promise<Comment[]>;
  comment(n: number, body: string): Promise<void>;
  memory(): Promise<{ number: number; body: string } | null>;
  rewriteMemory(n: number, body: string): Promise<void>;
  /** The issue this role is blocked on, if the board says it is. */
  blockedOn(): Promise<number | null>;
}

export interface Agent {
  prompt(text: string): void;
  steer(text: string): void;
  abort(): void;
  /** End this process; the executor starts the next, which is the fresh session. */
  finish(): void;
}

export interface Checks {
  /** Whether the role's branch carries a commit for this task. Advice only. */
  hasCommit(): Promise<boolean>;
}

/** What the worktree the role was handed says for itself. */
export interface Tree {
  /** The repository's guidance for roles, docs/factory-guidance.md, or null when it has none. */
  guidance(): Promise<string | null>;
}

export type Status = "done" | "blocked" | "failed";

export interface Outcome {
  status: Status;
  summary: string;
}

export type State =
  | { kind: "idle" }
  | { kind: "working"; issue: number; attempt: number }
  | { kind: "blocked"; issue: number; attempt: number };

export interface ActorOptions {
  role: string;
  capabilities: string[];
  /** Who this role is composed of (ADR-042); named in the brief so it agrees with the system prompt. */
  specialists?: string[];
  bus: Bus;
  board: Board;
  agent: Agent;
  checks: Checks;
  tree: Tree;
}

export class Actor {
  state: State = { kind: "idle" };
  private outcome: Outcome | null = null;
  private memoryIssue: number | null = null;
  private memoryBody = "";

  constructor(private readonly o: ActorOptions) {}

  /** session_start: read the memory; then say what this role can do, unless
   *  the board says it is blocked, in which case it holds and says nothing
   *  until asked (ADR-033 point 5). */
  async start(): Promise<void> {
    await this.readMemory();
    const blocked = await this.o.board.blockedOn();
    if (blocked !== null) {
      this.state = { kind: "blocked", issue: blocked, attempt: 0 };
      return;
    }
    await this.ready();
  }

  private async readMemory(): Promise<void> {
    const m = await this.o.board.memory();
    this.memoryIssue = m?.number ?? null;
    this.memoryBody = m?.body ?? "";
  }

  private async ready(): Promise<void> {
    this.state = { kind: "idle" };
    await this.o.bus.announce({ kind: "ready", capabilities: this.o.capabilities });
  }

  /** What arrived on the mailbox. */
  async handle(m: Message): Promise<void> {
    switch (m.kind) {
      case "assignment":
        return this.assigned(m.issue, m.attempt);
      case "steer":
        if (this.state.kind === "working") this.o.agent.steer(m.text);
        else this.o.agent.prompt(this.question(m.text));
        return;
      case "abort":
        if (this.state.kind === "working") this.o.agent.abort();
        return;
      case "reconcile":
        return this.o.bus.held(this.holding());
      default:
        return;
    }
  }

  private holding(): number[] {
    return this.state.kind === "idle" ? [] : [this.state.issue];
  }

  private async assigned(issue: number, attempt: number): Promise<void> {
    if (this.state.kind !== "idle") return;
    this.state = { kind: "working", issue, attempt };
    this.outcome = null;
    // The attempt's opening bracket on the events stream: what the executor
    // cuts a trace between, so what a task used is read off the stream
    // without a clock anyone has to share.
    await this.o.bus.event("task_started", { issue, attempt });
    await this.o.bus.ack(issue);
    const task = await this.o.board.issue(issue);
    const thread = await this.o.board.thread(issue);
    const guidance = await this.o.tree.guidance();
    this.o.agent.prompt(this.brief(task, thread, attempt, guidance));
  }

  /** The prompt a task starts with: the issue, its thread, the repository's
   *  own guidance when the worktree carries it, and what this role remembers. */
  private brief(task: Issue, thread: Comment[], attempt: number, guidance: string | null): string {
    const specialists = this.o.specialists ?? [];
    const lines = [
      `You are the role ${this.o.role}.`,
      ...(specialists.length > 0 ? [`Your specialists: ${specialists.join(", ")}.`] : []),
      `Task #${task.number}, attempt ${attempt}: ${task.title}`,
      "",
      task.body,
      "",
      "Thread so far:",
      ...thread.map((c) => `- ${c.by}: ${c.body}`),
      "",
      ...(guidance?.trim() ? ["this factory:", guidance.trim(), ""] : []),
      "Your memory from earlier tasks:",
      this.memoryBody || "(nothing yet)",
      "",
      "Commit your work on your own branch. When you are finished, or cannot finish, call report_outcome",
      "with done, blocked or failed and a summary; call update_memory with what the next task should know.",
    ];
    return lines.join("\n");
  }

  /** An operator's words to a role with no turn to steer: a question, put
   *  as one, answered in a turn of its own. The state does not move, so
   *  settling after it writes no outcome and ends no process, and an
   *  assignment that arrives meanwhile is taken as ever. */
  private question(text: string): string {
    return [
      `The operator asks: ${text}`,
      "",
      "Answer in words; you hold no task, so change nothing and report no outcome.",
    ].join("\n");
  }

  /** The agent's report_outcome tool. */
  async reportOutcome(outcome: Outcome): Promise<void> {
    this.outcome = outcome;
  }

  /** The agent's update_memory tool. */
  async updateMemory(body: string): Promise<void> {
    this.memoryBody = body;
    if (this.memoryIssue !== null) await this.o.board.rewriteMemory(this.memoryIssue, body);
  }

  /** agent_settled: the turn is over, so the outcome is written and the actor
   *  moves on. Done and failed end this process, because a fresh session is a
   *  fresh process (ADR-035 point 4 as amended); the next one announces ready.
   *  Blocked keeps the process, holding, so the task and the worktree stay. */
  async settled(): Promise<void> {
    if (this.state.kind !== "working") return;
    const { issue, attempt } = this.state;
    const outcome = this.outcome ?? { status: "failed", summary: "the session ended having reported no outcome" };
    let body = `outcome: ${outcome.status}\n\n${outcome.summary}`;
    if (outcome.status === "done" && !(await this.o.checks.hasCommit())) {
      body += "\n\nnote: no commit was found on this role's branch for this task";
    }
    await this.o.bus.event("task_ended", { issue, attempt, status: outcome.status });
    await this.o.board.comment(issue, body);
    if (outcome.status === "blocked") {
      this.state = { kind: "blocked", issue, attempt };
      return;
    }
    this.state = { kind: "idle" };
    this.o.agent.finish();
  }

  /** A turn or tool event, for the operator to watch. */
  async publish(name: string, payload: unknown): Promise<void> {
    await this.o.bus.event(name, payload);
  }

  /** Something worth every other role's knowing. */
  async share(text: string): Promise<void> {
    await this.o.bus.finding(text);
  }

  /** The bus came back after a restart: say again what the executor must know (ADR-033). */
  async reconnected(): Promise<void> {
    if (this.state.kind === "idle") await this.ready();
    else await this.o.bus.held(this.holding());
  }
}
