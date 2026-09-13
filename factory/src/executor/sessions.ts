// A role's session, started and restarted by the executor (ADR-035 point 4
// as amended): one process per task, so an exit after an outcome is the next
// process's start. The line that composes the session is the machine
// program's, and seam.bats asserts it; this only runs it.
import { spawn, type ChildProcess } from "node:child_process";
import type { Sessions } from "./core.js";

export interface SessionsOptions {
  factory: string;
  /** argv prefix; the machine program by default. Tests substitute a script. */
  command?: string[];
  restartDelayMs?: number;
  log?: (line: string) => void;
}

/**
 * The program a session is started with: the machine program, unless
 * CAGEWORKS_SESSION_COMMAND names another, which is how a harness runs the
 * factory on a host with scripted actors in place of cages. The line after
 * the program is the same either way.
 */
export function sessionCommand(env: Record<string, string | undefined>): string[] {
  const words = (env["CAGEWORKS_SESSION_COMMAND"] ?? "").split(/\s+/).filter(Boolean);
  return words.length ? words : ["cageworks-container"];
}

export class RoleSessions implements Sessions {
  private readonly children = new Map<string, ChildProcess>();
  private readonly wanted = new Set<string>();

  constructor(private readonly o: SessionsOptions) {}

  async start(role: string): Promise<void> {
    this.wanted.add(role);
    this.spawnOnce(role);
  }

  private spawnOnce(role: string): void {
    if (!this.wanted.has(role) || this.children.has(role)) return;
    const [cmd, ...prefix] = this.o.command ?? ["cageworks-container"];
    const args = [...prefix, "role-enter", "--signing-key", role, this.o.factory, role];
    // stdin is a pipe that is never written: pi in rpc mode reads it for a
    // client and exits on its end, and the extension is the client here.
    const child = spawn(cmd ?? "cageworks-container", args, { stdio: ["pipe", "inherit", "inherit"] });
    this.children.set(role, child);
    child.on("exit", (code) => {
      this.children.delete(role);
      this.o.log?.(`session ${role} exited with ${code}`);
      if (this.wanted.has(role)) setTimeout(() => this.spawnOnce(role), this.o.restartDelayMs ?? 2000);
    });
  }

  async stop(role: string): Promise<void> {
    this.wanted.delete(role);
    this.children.get(role)?.kill("SIGTERM");
  }

  running(): Set<string> {
    return new Set(this.children.keys());
  }
}
