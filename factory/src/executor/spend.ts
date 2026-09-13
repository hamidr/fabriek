// The proxy counts by source address (ADR-037 point 4) and the plan says
// which address is whose cage, so the executor names each count by its role
// before publishing and the TUI never learns an address. A count on an
// address the plan does not name is kept under the address: a spend nobody
// can attribute is still a spend.
export function spendByRole(counts: Record<string, number>, cages: Record<string, string>): Record<string, number> {
  const out: Record<string, number> = {};
  const named = new Set<string>();
  for (const [role, address] of Object.entries(cages)) {
    out[role] = counts[address] ?? 0;
    named.add(address);
  }
  for (const [key, n] of Object.entries(counts)) {
    if (key !== "total" && !named.has(key)) out[key] = n;
  }
  out["total"] = counts["total"] ?? 0;
  return out;
}
