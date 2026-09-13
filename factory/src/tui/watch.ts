// A watch that is kept (ADR-039 point 3): the relay's process, started again
// after a pause whenever it ends, because an ssh that dropped or a bus that
// restarted is not the operator's cue to type a command. Each start begins
// the picture over: a fresh relay replays from where it is told, and what
// was folded from the one before it is not known to still be true.
import { createInterface } from "node:readline";

export interface Watched {
  stdout: NodeJS.ReadableStream;
  on(event: "exit", cb: (code: number | null) => void): unknown;
}

export interface WatchOptions {
  spawn(): Watched;
  /** Before every start, the first included. */
  onStart(): void;
  /** One line from the relay. A throw is the line's fault and drops it. */
  onLine(line: string): void;
  onEnd(code: number | null): void;
  /** The pause before starting again. */
  pause(): Promise<void>;
}

export function keepWatching(o: WatchOptions): void {
  const start = (): void => {
    o.onStart();
    const child = o.spawn();
    createInterface({ input: child.stdout }).on("line", (line) => {
      try {
        o.onLine(line);
      } catch {
        // a line that is not the relay's is the relay's problem to say
      }
    });
    child.on("exit", (code) => {
      o.onEnd(code);
      void o.pause().then(start);
    });
  };
  start();
}
