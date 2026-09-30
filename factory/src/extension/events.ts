// What of a pi event the loop publishes for the operator to watch. pi's
// runtime hands an event more than its declared type: turn_end carries the
// whole session context three times over, which grew one role's events past
// the bus's limit and closed its connection on every turn (2026-09-30). So
// each event is projected onto the fields pi declares for it, and a
// history is published as its length.

type PiEvent = { type?: string } & Record<string, unknown>;

/** The fields of each event that travel, as pi declares them. */
const FIELDS: Record<string, string[]> = {
  agent_start: [],
  turn_start: ["turnIndex", "timestamp"],
  turn_end: ["turnIndex", "message", "toolResults"],
  tool_call: ["toolName", "toolCallId", "input"],
  tool_result: ["toolName", "toolCallId", "content", "isError"],
};

/** The payload a pi event is published with. */
export function eventPayload(event: PiEvent): Record<string, unknown> {
  if (event.type === "agent_end") {
    return { messages: Array.isArray(event["messages"]) ? event["messages"].length : 0 };
  }
  const payload: Record<string, unknown> = {};
  for (const key of FIELDS[event.type ?? ""] ?? []) {
    if (key in event) payload[key] = event[key];
  }
  return payload;
}
