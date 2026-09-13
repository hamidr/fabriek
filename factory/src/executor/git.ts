// Git as the executor runs it in the factory's clone (ADR-036 points 5 and
// 7): count a role's commits, push its branch to the forge, and mirror main
// and the record to origin on the operator's word. The forge is reached with
// the operator's token through a credential helper that reads a file, so the
// token is in no argument and no remote URL.
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
}

function git(cwd: string, args: string[], env: Record<string, string> = {}): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile("git", ["-C", cwd, ...args], { env: { ...process.env, ...env } }, (err, stdout, stderr) => {
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

  async tip(branch: string): Promise<string | null> {
    const out = await git(this.o.clone, ["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`]).catch(() => "");
    return out.trim() || null;
  }

  async commitsSince(branch: string, since: string | null): Promise<number> {
    const out = await git(this.o.clone, ["rev-list", "--count", `${since ?? this.base}..${branch}`]).catch(() => "0");
    return Number(out.trim()) || 0;
  }

  async push(branch: string): Promise<void> {
    await git(this.o.clone, ["push", this.o.forgeUrl, `refs/heads/${branch}:refs/heads/${branch}`], this.helper());
  }

  /** main and refs/fabriek/record to origin, together (ADR-036 point 7). */
  async mirror(): Promise<void> {
    await git(this.o.clone, ["fetch", this.o.forgeUrl, `refs/heads/${this.base}:refs/heads/${this.base}`], this.helper());
    if (this.o.record) {
      const dir = await mkdtemp(join(tmpdir(), "record-"));
      try {
        await writeFile(join(dir, "issues.json"), await this.o.record());
        const tree = await git(this.o.clone, ["--work-tree", dir, "add", "-A", "--", "."], { GIT_INDEX_FILE: join(dir, "index") });
        void tree;
        const written = (await git(this.o.clone, ["write-tree"], { GIT_INDEX_FILE: join(dir, "index") })).trim();
        const commit = (await git(this.o.clone, ["commit-tree", written, "-m", "the record, mirrored"], {
          GIT_AUTHOR_NAME: "fabriek", GIT_AUTHOR_EMAIL: "fabriek@invalid",
          GIT_COMMITTER_NAME: "fabriek", GIT_COMMITTER_EMAIL: "fabriek@invalid",
        })).trim();
        await git(this.o.clone, ["update-ref", "refs/fabriek/record", commit]);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    }
    await git(this.o.clone, ["push", "origin", `refs/heads/${this.base}:refs/heads/${this.base}`, "+refs/fabriek/record:refs/fabriek/record"]);
  }
}
