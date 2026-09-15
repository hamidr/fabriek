// The relay's argv (ADR-039 point 2): --from <id> for where every stream
// is first read after, and --stream <name>, repeatable, for reading some
// streams and not all. Pure, so the usage is asserted as data.

export interface RelayArgs {
  from: string;
  streams: string[];
}

export function relayArgs(argv: string[], relayed: string[]): RelayArgs {
  let from = "$";
  const streams: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === "--from" || flag === "--stream") {
      if (value === undefined || value.startsWith("--")) throw new Error(`${flag} needs a value`);
      if (flag === "--from") from = value;
      else if (!relayed.includes(value)) throw new Error(`${value} is not a stream this factory relays`);
      else streams.push(value);
      i++;
    } else {
      throw new Error(`unknown argument ${flag}`);
    }
  }
  return { from, streams: streams.length > 0 ? streams : relayed };
}
