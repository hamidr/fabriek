// The board as the executor writes it (ADR-036): issues, their labels, their
// assignee and their thread, and pull requests. Labels are set by id, and the
// ids are looked up once per name; a label the forge lacks is a build or a
// prepare that did not run, and is reported as such.
import { ForgeClient, type Comment } from "../forge/client.js";
import type { Board, BoardIssue } from "./core.js";

interface RawIssue {
  number: number;
  title: string;
  body: string | null;
  state: "open" | "closed";
  labels: { id: number; name: string }[];
  assignees: { login: string }[] | null;
}

export class ForgeBoard implements Board {
  private labelIds = new Map<string, number>();

  constructor(
    private readonly forge: ForgeClient,
    private readonly repo: string,
    private readonly base = "main",
  ) {}

  private toIssue(r: RawIssue, thread: Comment[]): BoardIssue {
    return {
      number: r.number,
      title: r.title,
      body: r.body ?? "",
      state: r.state,
      labels: r.labels.map((l) => l.name),
      assignee: r.assignees?.[0]?.login ?? null,
      thread,
    };
  }

  private async labelId(name: string): Promise<number> {
    if (!this.labelIds.has(name)) {
      const all = await this.forge.call<{ id: number; name: string }[]>("GET", `${this.repo}/labels?limit=100`);
      this.labelIds = new Map(all.map((l) => [l.name, l.id]));
    }
    const id = this.labelIds.get(name);
    if (id === undefined) throw new Error(`the forge has no label ${name}; fabriek up makes it`);
    return id;
  }

  async open(): Promise<BoardIssue[]> {
    const raw = await this.forge.call<RawIssue[]>("GET", `${this.repo}/issues?state=open&type=issues&limit=100`);
    const out: BoardIssue[] = [];
    for (const r of raw) {
      if (r.labels.some((l) => l.name === "memory")) continue;
      out.push(this.toIssue(r, await this.forge.thread(r.number)));
    }
    return out;
  }

  async issue(n: number): Promise<BoardIssue> {
    const r = await this.forge.call<RawIssue>("GET", `${this.repo}/issues/${n}`);
    return this.toIssue(r, await this.forge.thread(n));
  }

  async create(title: string, body: string, stage: string): Promise<number> {
    const r = await this.forge.call<{ number: number }>("POST", `${this.repo}/issues`, {
      title,
      body,
      labels: [await this.labelId(stage)],
    });
    return r.number;
  }

  async setLabels(n: number, labels: string[]): Promise<void> {
    const ids: number[] = [];
    for (const l of labels) ids.push(await this.labelId(l));
    await this.forge.call("PUT", `${this.repo}/issues/${n}/labels`, { labels: ids });
  }

  async assign(n: number, role: string | null): Promise<void> {
    await this.forge.call("PATCH", `${this.repo}/issues/${n}`, { assignees: role ? [role] : [] });
  }

  async comment(n: number, body: string): Promise<void> {
    await this.forge.comment(n, body);
  }

  async close(n: number): Promise<void> {
    await this.forge.call("PATCH", `${this.repo}/issues/${n}`, { state: "closed" });
  }

  async openPullRequest(branch: string, title: string): Promise<number> {
    const existing = await this.forge.call<{ number: number; head: { ref: string } }[]>("GET", `${this.repo}/pulls?state=open&limit=100`);
    const mine = existing.find((p) => p.head.ref === branch);
    if (mine) return mine.number;
    const r = await this.forge.call<{ number: number }>("POST", `${this.repo}/pulls`, { head: branch, base: this.base, title });
    return r.number;
  }
}
