// What the TUI types at the launcher on the operator's behalf (ADR-039
// point 3), in the launcher's grammar (ADR-047): the factory as -f, then
// one verb and its own words. Defined once so a change to the grammar
// lands in one place and a test reads as the line an operator would type.

/** The launcher's line for one verb of one factory. */
export function cliArgs(factory: string, verb: string, rest: string[]): string[] {
  return ["-f", factory, verb, ...rest];
}

/**
 * The line that starts a watch: from 0-0, so what the bus still holds is
 * replayed and the board, which reaches the TUI only as the executor's
 * periodic event, is on screen at open rather than at the next tick.
 */
export function watchArgs(factory: string): string[] {
  return cliArgs(factory, "watch", ["--from", "0-0"]);
}
