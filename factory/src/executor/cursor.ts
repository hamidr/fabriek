// The id the executor last read on the operator's stream, kept as a file
// beside the state so a restart resumes where it left off: the operator's
// interventions are a queue, and one filed while the executor was down or
// still reconciling is owed an answer, not dropped. Without a cursor, the
// caller's fallback (the stream's tail) is where reading starts.
import { readFileSync, renameSync, writeFileSync } from "node:fs";

export function resumeFrom(file: string, fallback: string): string {
  try {
    const id = readFileSync(file, "utf8").trim();
    return id || fallback;
  } catch {
    return fallback;
  }
}

/** Written by rename, so a reader never sees half an id. */
export function remember(file: string, id: string): void {
  writeFileSync(`${file}.new`, `${id}\n`);
  renameSync(`${file}.new`, file);
}
