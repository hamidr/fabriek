// Git as the executor runs it in the factory's clone (ADR-036 points 5 and
// 7): count a role's commits, push its branch to the forge, and on the
// operator's word bring merged main and the record into the clone, where
// the operator's own fetch finds them (ADR-067 point 5): nothing here
// writes the operator's checkout. The forge is reached with the operator's
// token through a credential helper that reads a file, so the token is in
// no argument and no remote URL.
import { execFile } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Git } from "./core.js";

export interface GitOptions {
  clone: string;
  base?: string;
  forgeUrl: string;
  forgeTokenFile: string;
  /** What the record is exported as, when mirroring. */
  record?: () => Promise<string>;
  /**
   * The words git runs behind when the clone is in the factory's machine
   * (ADR-070): nixcage's machine exec. The environment does not cross it,
   * so what git is given in its environment goes as `env` words instead.
   */
  command?: string[];
  /**
   * The clone the record is written in, on this host: the machine's clone
   * is a disk this host does not read, and the record is pushed to the
   * forge, where the operator fetches it. The clone itself when absent.
   */
  recordClone?: string;
}

function git(
  cwd: string,
  args: string[],
  env: Record<string, string> = {},
  command: string[] = [],
): Promise<string> {
  const [program, argv, extra] = command.length
    ? [
        command[0] as string,
        [...command.slice(1), "env", ...Object.entries(env).map(([k, v]) => `${k}=${v}`), "git", "-C", cwd, ...args],
        {},
      ]
    : ["git", ["-C", cwd, ...args], env];
  return new Promise((resolve, reject) => {
    execFile(program, argv, { env: { ...process.env, ...extra } }, (err, stdout, stderr) => {
      if (err) reject(new Error(`git ${args[0]}: ${stderr.trim() || err.message}`));
      else resolve(stdout);
    });
  });
}

export class CloneGit implements Git {
  constructor(private readonly o: GitOptions) {}

  private get base(): string {
    return this.o.base ?? "main";
  }

  /** git reads the operator's token from the file each time, never from argv. */
  private helper(): Record<string, string> {
    return {
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: "credential.helper",
      GIT_CONFIG_VALUE_0: `!f() { echo username=operator; echo "password=$(cat ${this.o.forgeTokenFile})"; }; f`,
    };
  }

  /** git in the clone roles commit in, wherever that clone is. */
  private inClone(args: string[], env: Record<string, string> = {}): Promise<string> {
    return git(this.o.clone, args, env, this.o.command ?? []);
  }

  async tip(branch: string): Promise<string | null> {
    const out = await this.inClone(["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`]).catch(() => "");
    return out.trim() || null;
  }

  async commitsSince(branch: string, since: string | null): Promise<number> {
    const out = await this.inClone(["rev-list", "--count", `${since ?? this.base}..${branch}`]).catch(() => "0");
    return Number(out.trim()) || 0;
  }

  async push(branch: string): Promise<void> {
    await this.inClone(["push", this.o.forgeUrl, `refs/heads/${branch}:refs/heads/${branch}`], this.helper());
  }

  /**
   * main into the clone roles start from, and refs/fabriek/record written
   * beside it (ADR-036 point 7). With the roles in a machine the record is
   * written in this host's clone and pushed to the forge, where the
   * operator's fetch finds it (ADR-070 point 8).
   */
  async mirror(): Promise<void> {
    await this.inClone(["fetch", this.o.forgeUrl, `refs/heads/${this.base}:refs/heads/${this.base}`], this.helper());
    const here = this.o.recordClone ?? this.o.clone;
    const local = this.o.command === undefined || this.o.recordClone !== undefined;
    if (this.o.record && local) {
      const dir = await mkdtemp(join(tmpdir(), "record-"));
      try {
        await writeFile(join(dir, "issues.json"), await this.o.record());
        const tree = await git(here, ["--work-tree", dir, "add", "-A", "--", "."], { GIT_INDEX_FILE: join(dir, "index") });
        void tree;
        const written = (await git(here, ["write-tree"], { GIT_INDEX_FILE: join(dir, "index") })).trim();
        const commit = (await git(here, ["commit-tree", written, "-m", "the record, mirrored"], {
          GIT_AUTHOR_NAME: "fabriek", GIT_AUTHOR_EMAIL: "fabriek@invalid",
          GIT_COMMITTER_NAME: "fabriek", GIT_COMMITTER_EMAIL: "fabriek@invalid",
        })).trim();
        await git(here, ["update-ref", "refs/fabriek/record", commit]);
        if (this.o.recordClone !== undefined) {
          await git(here, ["push", "--force", this.o.forgeUrl, "refs/fabriek/record:refs/fabriek/record"], this.helper());
        }
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    }
  }
}
