---
id: ADR-027
title: A factory is observed from three sources, and a role owns none of them
status: accepted
date: 2026-09-07
status_date: 2026-09-07
summary: three independent sources record what a factory does: the loop's tap, the egress proxy and the guest kernel
depends_on: [ADR-018, ADR-019, ADR-025, ADR-026]
supersedes: []
superseded_by: []
---

## Context

Nothing here records what a factory did. A dropped packet is silent, because
ADR-025's chain ends in a policy and not a log. The proxy that holds the
credential sees every request arrive from `127.0.0.1`, so the spend has no
owner. And ADR-026 gives the loop the agent's stdio, which means the only
account of what a role attempted will exist in a pipe that nothing reads twice.

Reading the pieces already decided settles most of the design.

pi's RPC mode is JSONL over stdin and stdout with a single client (ADR-026).
There is no second place to take those events from. Whatever collects them is
the loop or it is nothing.

The loop and the agent it supervises are one uid. `--private-users=<uid>:1`
maps a session onto one principal and pi's surface includes `bash`, which
ADR-026 already records as the reason an intervention's attribution is stated
rather than claimed. The same fact applies to a log: a file the loop can write
is a file the agent can rewrite. A role's own account of itself is evidence
about a role that is behaving.

The guest kernel can answer independently. `nixpkgs.linuxPackages` at 6.18.49
ships `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_EVENTS`, `CONFIG_DEBUG_INFO_BTF` and
`CONFIG_KPROBES`, so a probe in the machine's init namespace sees every process
in every cage of that factory, attributed by the uid nixcage allocated. Cages
share the machine's kernel, which is the same fact ADR-025's uid filter rests
on.

## Decision

**1. Three sources, and they are never merged into one truth.** The loop's tap
is what a role says it did. The egress proxy is what it spent. The kernel is
what it ran. They differ in what a role can influence, and collapsing them into
one stream would throw that away.

**2. The loop tees its own pipe.** One record read, one record relayed to the
console socket, one record to the ledger. It does not subscribe to the socket
it serves: a subscriber is a watcher, and a watcher joins a running stream
through a snapshot, which is the gap ADR-026 sends to `models/console-watch.qnt`.
A tap in line with the pipe never joins anything.

**3. The stream splits into a ledger and a transcript.** The ledger carries the
event kind, when, which role and uid, which task, which turn, which tool, how
long it took and how it ended. The transcript carries `message_update` text and
the inputs of `tool_execution_*`, on a runtime path under the state directory
and not in the role's worktree, for the reason ADR-026 point 2 keeps the console
socket out of it: a worktree is a git working tree the role commits from. Only
the ledger is read by anything of ours. The supervisor is content-blind and
stays so; the ledger is metadata by construction rather than by care.

**4. journald is the writer, because it stamps the identity.** It reads
`SO_PEERCRED` off its socket and records `_UID` and `_PID` itself. A role can
write a line that lies about what it did. It cannot write a line that lies
about who it is, and it cannot alter a line already written. Nothing writes the
ledger as a plain file under a role's uid, which would be a record a role could
edit.

**5. The socket reaches the loop as a bind, and a role session's argv changes.**
A cage is `systemd-nspawn --directory=<rootfs>` with a `/run` of its own, so
`/run/systemd/journal/socket` is not there until it is asked for. It is asked
for with `--bind`, which is inside the enter primitive and needs nothing new
from nixcage. Under `--private-users=<uid>:1` the credential journald reads
back is the role's allocated uid, which is the same number ADR-025's chain
filters on, so the two sources agree on who a role is without either being told.

**6. The journal is namespaced per factory, because eviction is a shared
resource.** One journal for the machine would let a role that floods it evict
every other role's entries under `SystemMaxUse`, which would make suppressing
evidence a matter of writing enough of it. What point 4 promises is that an
entry's identity is not forgeable; it does not promise an entry survives, and a
shared bucket is where that distinction gets expensive.

**7. The tap never blocks the agent, and that covers both sinks.** The journal
socket is a datagram socket and a full queue is a real state, so a synchronous
write in the loop would backpressure pi's stdout and stall the turn. The same
is true of the console socket ADR-026 point 3 relays to, which is a thing this
document said nothing about until `models/ledger-tap.qnt` was run: a watcher
reading slower than the agent writes is a loop that waits, and a loop that
waits is a pipe that fills and an agent that stops. Both writes are made
without blocking. A refused ledger write becomes a counted gap in the ledger; a
refused relay drops that frame for the watchers, who recover by asking the
agent for the transcript, which ADR-026 point 3 already has a joiner do. A
ledger with a hole in it that says so is worth more than a factory that stops
to keep one, and a watcher that missed a frame it can ask for again is worth
more than either.

**8. The journal lives on the pool, asked for the way everything else is.**
microvm.nix gives the guest a tmpfs root, so a persistent journal is one that
has been put somewhere on purpose. It is asked for with
`nixcage-container storage ensure <path> <uid> <quota>` and never with `zfs`:
the primitive already takes a bound, and whether the path becomes a dataset is
nixcage's to decide (ADR-017, ADR-018). The path is a sibling of `worktrees/`
under the state directory, so no role's name can reach it. Unbounded it would
fill the pool and take every worktree with it, which is why the quota is not
optional here.

The quota is `resources.journalQuota`, declared by the factory and capped by
the operator the way `roleQuota` already is, because a bound that lived in a
module would be one no factory could size and no operator could refuse. A
machine told nothing falls back to its own default rather than to none:
refusing to boot over an unstated number would be a worse answer than a modest
one. journald's own `SystemMaxUse` is set below it, so the ledger rotates
before the quota refuses a write; a full dataset is a ledger that stops, and an
evicting one is a ledger that says so.

**9. The kernel probes observe and do not enforce.** `sched_process_exec`,
`sched_process_exit` and socket connect, filtered in kernel, out through a ring
buffer. Not `openat`, which is orders of magnitude more traffic for a question
nobody has asked. `CONFIG_BPF_LSM` is available and is not used: denying a role
an exec is the shape of a cage, and a cage is nixcage's (ADR-018).

**10. The proxy logs metadata and never a header or a body.** The request line,
the status, the timing, the byte counts and the upstream's own rate-limit
response headers, to the journal rather than to a file, since a file on a tmpfs
root is a log that ends at the next stop. A log format naming `$http_*` would
put this factory's credential in a file, which is the thing ADR-025 exists to
keep out of the store and out of a build log.

**11. There is no database.** The ledger is journald, exported as NDJSON and
queried with DuckDB. ADR-013 refuses a shared database for the record: that is
about work, which several roles read and which travels with the repository. A
ledger is machine-local, single-writer and travels nowhere, so it is a
different object, and it is said here so that it does not read as a breach of
that decision. A daemon would cost RSS out of the factory's declared memory, a
unit to supervise and a schema to migrate, and would buy indexes for a query
nobody has yet.

**12. Reading is the operator's and the console's.** Cross-factory questions are
answered on the operator's host, over the copies pulled into the machine
directory, because two factories share no kernel and no pool and no query
inside one can see the other. The supervisor is given no reader: it would be a
new dependency and a new surface on the invariant point 3 protects, for a
capability it does not need.

## Consequences

**A role can suppress its own record even though it cannot forge its
identity.** Point 6 buys a bucket per factory, not per role, so within one
factory a flood still evicts. Making that impossible needs a journal per role,
which is a namespace per uid and a cost per role rather than per machine, and
it is not bought here. The kernel source is what does not go quiet.

**A role can still forge its own ledger.** Point 4 makes identity unforgeable
and content is not: an agent with `bash` can write whatever it likes under its
own uid. What changes is that the lie is now checkable, since a
`tool_execution_bash` that never happened has no matching
`sched_process_exec`, and one that happened unreported has the exec and no
event. The property is a cross-check, not proof, and it is stated that way for
the same reason ADR-026 states its own.

**The transcript is prompts and file contents in plaintext on the pool.** This
is the widest thing here. Whoever reads that dataset reads everything every
agent saw and wrote. It is kept because a console with no transcript cannot
show a late joiner what happened, and it is kept apart from the ledger so that
the decision to read it is always a deliberate one.

**Observability follows the console into being agent-specific.** ADR-026 point
9 already says a role whose agent speaks no such protocol has no console. It
now has no ledger either. The proxy and the kernel still see it, which is the
argument for not having built this on the agent alone.

**A loop that dies holding a gap leaves a hole nothing names.** A refused
ledger write is counted in the loop and reaches the journal at the next free
slot, because naming it any sooner needs the slot that was just refused.
`models/ledger-tap.qnt` reaches the state where the unit dies inside that
window: the records are gone and the ledger does not say so. Closing it means
waiting for the slot, which is the blocking write point 7 exists to remove, so
it is not closed. The kernel source is again what does not go quiet.

**The probes cost the factory.** The RSS and the CPU come out of the memory and
the cores the declaration asked for and the operator allowed. What that costs
is measured rather than asserted, below.

**A stop and start has one more thing to survive.** The journal dataset joins
the pool manifest PRD-004 phase 2 checks, because a ledger that does not come
back is a ledger nobody can rely on after the first restart.

## Design gates

The Formal Modeling Gate fires on points 3 and 4: this is a permission model,
and the entities are a role, its loop, the journal and two streams with
different readers. `models/factory-structure.als` now carries a ledger and a
transcript beside the worktree and the refs it already had, over five
assertions: an entry's uid identifies exactly the role that wrote it, no role
owns the ledger it writes to, neither the ledger nor the transcript is
somewhere a role commits from, and the supervisor reaches no transcript.
`alloy6 exec models/factory-structure.als` reports UNSAT for all five at scope
6 but 18 Path, and deleting the facts they rest on turns all five SAT. The
console socket joins them when ADR-026 is built.

The scope is not the uniform 6 it was. A role holds three paths now, so six of
them is two roles' worth and `NonTrivialFactory`, which wants three roles, went
UNSAT the moment the ledger arrived: a witness that stops being reachable
because the scope ran out is a scope bug reported as a design one.

A second gate fires on point 7. The tap is in line with the pipe, so it has
none of the join ADR-026 sends to `models/console-watch.qnt`, but it does have
a bounded queue between a reader that must not stall and a writer that may
refuse. `models/ledger-tap.qnt` was written and run before any of this was
built, over the interleavings of read, relay, ledger write, drain, gap
announcement and a unit that dies. It carries four invariants: the tap never
waits, no record leaves the pipe without a disposition, every refusal is named
in the ledger or held for the next slot or lost with the loop, and a dropped
console frame costs the ledger nothing. `quint run --invariant=allInvariants
--max-steps=60 --max-samples=200000` reports no violation. Four witnesses
stated as negations all violate, so the model reaches the refusal, the stalled
agent, the dropped frame and the crash rather than passing by never getting
there, and turning either refusal back into a write that waits turns
`theTapNeverWaits` red.

The model changed the design twice. Point 7 covered only the ledger, and
`theTapNeverWaits` violated in 632ms through the console relay, which is why
point 7 now names both sinks. And `noSilentHoleFromACrash` violates and is
deliberately left out of `allInvariants`, because the window it finds cannot be
closed without the write point 7 exists to remove; it is recorded in the
consequences instead of repaired.

## Measurement plan

Every number this document depends on is measured on a real machine, because a
rate guessed from the probe list is a rate that will be wrong by an order of
magnitude in whichever direction is inconvenient.

```bash
# Event rate: one real role session, counted at the journal.
tests/manual/observe.sh rate
# reports entries per second by source (ledger, proxy, kernel) over the run

# Storage: bytes the journal dataset actually holds, compressed.
tests/manual/observe.sh storage
# zfs get -Hp used,logicalused,compressratio cageworks-<factory>/state/journal

# Overhead: a fixed workload with the probes loaded and without them.
tests/manual/observe.sh overhead
# reports wall clock and peak RSS for both, three runs each
```

Two attributions are checked rather than assumed, because both cross a user
namespace: that journald stamps a caged writer with the role's allocated uid,
and that a kernel probe reports the same number `meta skuid` filters on. They
are the same claim from two directions and neither is worth asserting from a
header file.

The retention window is set from the storage number against
`cageworks.machine.diskSize`, and is written into the declaration's schema only
once that number exists. Until then the quota is the only bound.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
nix develop --command bats tests/command/seam.bats
alloy6 exec models/factory-structure.als
quint run models/ledger-tap.qnt --invariant=allInvariants --max-steps=60 --max-samples=200000
docmeta-check docs && docmeta-tracker --check docs
CAGEWORKS_PROOF_DIR=/tmp/proof tests/manual/observe.sh
```

The suite asserts what the ledger is rather than what it says: a ledger entry
carries the uid journald stamped and not one the record claims, a transcript
path is not reachable by anything given the ledger, a role's principal cannot
write another role's entries, the journal dataset has a quota and the pool
survives filling it, and a factory whose agent speaks no RPC still produces
proxy and kernel events. `seam.bats` is named on its own because point 5 does
change the argv a role session composes: the journal socket arrives as one more
`--bind`, and that diff is the file's purpose.
