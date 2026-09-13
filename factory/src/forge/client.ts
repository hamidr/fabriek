// The forge over its API (ADR-036). The token is read from a file each time
// it is needed, so a rotated token is picked up and none is ever held in a
// long-lived variable; it travels as a header and never on a command line.
import { readFileSync } from "node:fs";

export interface ForgeOptions {
  base: string;
  owner: string;
  repo: string;
  tokenFile: string;
}

export interface Issue {
  number: number;
  title: string;
  body: string;
  labels: string[];
  assignee: string | null;
}

export interface Comment {
  by: string;
  body: string;
}

export class ForgeError extends Error {
  override name = "ForgeError";
}

export class ForgeClient {
  constructor(private readonly o: ForgeOptions) {}

  private get repo(): string {
    return `/repos/${this.o.owner}/${this.o.repo}`;
  }

  async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const token = readFileSync(this.o.tokenFile, "utf8").trim();
    const init: RequestInit = { method, headers: { authorization: `token ${token}`, "content-type": "application/json" } };
    if (body !== undefined) init.body = JSON.stringify(body);
    const res = await fetch(this.o.base + path, init);
    if (!res.ok) throw new ForgeError(`${res.status} from ${method} ${path}`);
    const text = await res.text();
    return (text ? JSON.parse(text) : null) as T;
  }

  async issue(n: number): Promise<Issue> {
    const r = await this.call<{ number: number; title: string; body: string | null; labels: { name: string }[]; assignees: { login: string }[] | null }>(
      "GET",
      `${this.repo}/issues/${n}`,
    );
    return { number: r.number, title: r.title, body: r.body ?? "", labels: r.labels.map((l) => l.name), assignee: r.assignees?.[0]?.login ?? null };
  }

  /** Who said what, oldest first. The executor writes with the owner's token, so the owner's words read as the executor's. */
  async thread(n: number): Promise<Comment[]> {
    const r = await this.call<{ user: { login: string }; body: string }[]>("GET", `${this.repo}/issues/${n}/comments`);
    return r.map((c) => ({ by: c.user.login === this.o.owner ? "executor" : c.user.login, body: c.body }));
  }

  async comment(n: number, body: string): Promise<void> {
    await this.call("POST", `${this.repo}/issues/${n}/comments`, { body });
  }

  /** A role's memory issue: labelled memory and posted by that role (ADR-036 point 3). */
  async memory(role: string): Promise<{ number: number; body: string } | null> {
    const r = await this.call<{ number: number; body: string | null; user: { login: string } }[]>(
      "GET",
      `${this.repo}/issues?state=all&labels=memory&type=issues&limit=50`,
    );
    const mine = r.find((i) => i.user.login === role);
    return mine ? { number: mine.number, body: mine.body ?? "" } : null;
  }

  async rewriteMemory(n: number, body: string): Promise<void> {
    await this.call("PATCH", `${this.repo}/issues/${n}`, { body });
  }

  /** The open issue labelled blocked and assigned to a role, if any (ADR-033 point 5). */
  async blockedOn(role: string): Promise<number | null> {
    const r = await this.call<{ number: number; assignees: { login: string }[] | null }[]>(
      "GET",
      `${this.repo}/issues?state=open&labels=blocked&type=issues&limit=50`,
    );
    const mine = r.find((i) => i.assignees?.some((a) => a.login === role));
    return mine ? mine.number : null;
  }
}
