// What the executor writes into a thread and reads back from it (ADR-034
// point 4): an attempt line when it sends a task, naming the stage and
// where the role's branch stood, and the count of those lines when it
// decides whether a task has attempts left. Counted per stage, so each
// stage has the declared budget and a later stage starts at one, whichever
// role serves it. The decider reads the same lines to show the board.
export interface Said {
  by: string;
  body: string;
}

const ATTEMPT = /^attempt (\d+) started for (\S+) at (\S+) \(branch at (\S+)\)/;

export function attemptLine(attempt: number, role: string, stage: string, tip: string | null): string {
  return `attempt ${attempt} started for ${role} at ${stage} (branch at ${tip ?? "none"})`;
}

/** The executor's attempt lines for one stage. */
export function attemptsAt(thread: Said[], stage: string): number {
  return thread.filter((c) => c.by === "executor" && ATTEMPT.exec(c.body)?.[3] === stage).length;
}

/** The branch tip an attempt line recorded, or null for none or for no attempt line. */
export function tipOf(body: string): string | null {
  const tip = ATTEMPT.exec(body)?.[4];
  return tip && tip !== "none" ? tip : null;
}

export function isAttemptLine(body: string): boolean {
  return ATTEMPT.test(body);
}
