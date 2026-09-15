// The decider (ADR-034): judgement in a cage. It composes the prompt out of
// four parts, three the machine's and one the repository's, and passes the
// model's tool calls through the vocabulary and the declaration before any
// reaches the bus, so what the executor receives is already a command and
// never prose. The executor validates again against the board; this gate is
// the model's feedback, not the executor's safety.
import { parseCommand, CommandError, type Command } from "../vocabulary.js";
import { stageOf, type Declaration } from "../declaration.js";

export interface IssueView {
  number: number;
  title: string;
  stage: string | null;
  assignee: string | null;
  attempts: number;
  blocked: boolean;
  lastOutcome: string | null;
}

export interface Snapshot {
  issues: IssueView[];
  ready: string[];
  /** Whether the executor is still routing (ADR-037 point 4). */
  routing: boolean;
}

export interface Commands {
  send(c: Command): Promise<void>;
}

export interface DeciderOptions {
  declaration: Declaration;
  /** The policy file the repository names (ADR-034 point 5), or null. */
  policy: string | null;
  commands: Commands;
}

export type Result = { ok: true } | { ok: false; reason: string };

export const RULES = `You are the decider of a software factory. You read the board and choose
what the executor does next. You act only through the tools assign, retry,
block, file, push and stop; the executor refuses anything the declaration does
not permit, and refuses is what you will see. You never write code, comments
or issues yourself: file makes an issue from files you write first.

Rules the machine holds you to:
- A task goes to a ready role that provides what its stage needs.
- No more tasks are in flight at once than the declaration allows; an
  assign past that is refused, so finish or free one first.
- A task that failed may be retried up to the declared attempts; retry goes
  back to the same role. A task past its attempts is one to block or leave.
- A blocked task waits on something; say what with block.
- Push a role's branch when its work at a stage is done and reviewable.
- Stop a role only when its turn is doing harm; stopping keeps its task.
- When nothing should happen, call wait. Do not invent work.`;

export class Decider {
  constructor(private readonly o: DeciderOptions) {}

  /** The four parts, in order, each labelled so the model can tell whose words are whose. */
  prompt(s: Snapshot): string {
    const d = this.o.declaration;
    const roles = Object.entries(d.roles).map(([n, r]) => `- ${n}: provides ${r.provides.join(", ")}`);
    const workflows = Object.entries(d.workflows).map(
      ([n, w]) => `- ${n}: ${w.stages.map((st, i) => `${i + 1}. ${st.needs}${st.done ? ` (done: ${st.done})` : ""}`).join("; ")}`,
    );
    const issues = s.issues.length
      ? s.issues.map((i) => {
          const parts = [`#${i.number} "${i.title}"`, `stage: ${i.stage ?? "none"}`, `assignee: ${i.assignee ?? "nobody"}`, `attempts: ${i.attempts}`];
          if (i.blocked) parts.push("blocked");
          let line = `- ${parts.join(", ")}`;
          if (i.lastOutcome) line += `\n  last outcome: ${i.lastOutcome.replace(/\n+/g, " ")}`;
          return line;
        })
      : ["(no open issues)"];
    return [
      "# Rules",
      RULES,
      "",
      "# Declaration",
      `factory: ${d.name}`,
      "roles:",
      ...roles,
      "workflows:",
      ...workflows,
      `attempts per task: ${d.resources.taskAttempts}`,
      `tasks in flight at once: ${d.resources.concurrency > 0 ? d.resources.concurrency : "one per role"}`,
      "",
      "# Board",
      ...issues,
      `ready: ${s.ready.length ? s.ready.join(", ") : "(nobody)"}`,
      s.routing ? "routing: on" : "routing: stopped at the soft limit; nothing new will be assigned",
      "",
      "# Policy",
      this.o.policy?.trim() || "(the repository declares none)",
    ].join("\n");
  }

  /** A tool call from the model: through the vocabulary and the declaration, then to the bus. */
  async command(raw: unknown): Promise<Result> {
    let c: Command;
    try {
      c = parseCommand(raw);
    } catch (e) {
      return { ok: false, reason: e instanceof CommandError ? e.message : String(e) };
    }
    const d = this.o.declaration;
    const workflow = Object.keys(d.workflows)[0] ?? "";
    switch (c.verb) {
      case "assign":
      case "push":
      case "stop":
        if (!(c.role in d.roles)) return { ok: false, reason: `no role ${c.role} is declared` };
        break;
      case "file":
        if (!stageOf(d, workflow, c.stage)) return { ok: false, reason: `no stage ${c.stage} in workflow ${workflow}` };
        break;
      default:
        break;
    }
    await this.o.commands.send(c);
    return { ok: true };
  }
}
