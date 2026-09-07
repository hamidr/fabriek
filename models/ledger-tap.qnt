// The tap that splits a role's agent stream into a console relay and a ledger,
// as decided in point 7 of docs/ADR-027-observed-from-three-sources.md and
// relayed to the console socket point 3 of
// docs/ADR-026-the-console-is-the-loop.md exposes.
//
// The loop owns the agent's stdout pipe. For each record it reads, it relays
// one copy to the console socket and writes one to the journal. Both sinks are
// sockets with a bounded queue, and both queues can be full: the journal
// because journald is behind a datagram socket, the console because a watcher
// can read slower than the agent writes.
//
// ADR-027 point 7 says the tap never blocks the agent: a refused write becomes
// a counted gap rather than a pause. The first run of this model had the
// console relay as what a socket write is by default, one that waits for room,
// because ADR-026 point 3 says nothing about a watcher that reads slower than
// the agent writes. theTapNeverWaits violated in 632ms: the loop waits on the
// console, and a loop that waits is a pipe that fills and an agent that stops.
// Point 7 was widened to both sinks because of it, and the relay is modelled
// below as the refusal it now is.
//
// Break test: turn either refusal back into a write that waits and
// theTapNeverWaits turns red at the first full queue. Done for both sinks, so
// the invariant is a property of the design rather than of the transition list.
module ledgerTap {
  // Two of everything, because one hides the interleaving and three only
  // repeats it. Four records is enough to fill a queue, drain it and fill it
  // again.
  pure val pipeCap = 2
  pure val journalCap = 2
  pure val consoleCap = 2
  pure val maxRecords = 4

  // The agent and the pipe between it and the loop.
  var produced: int
  var pipeLen: int

  // The record the loop has in hand, and what it has done with it.
  var holding: bool
  var relayDone: bool
  var ledgerDone: bool

  // The two sinks.
  var consoleLen: int
  var journalLen: int

  // The ledger's account of itself.
  var ledgered: int
  var dropped: int
  var relayDropped: int
  var gapHeld: int
  var gapNamed: int
  var gapLost: int

  var crashed: bool
  var recordsLost: int

  // Witnesses. The first must stay false; the rest are states the design has
  // to be able to reach, or the model is not describing it.
  var loopWaited: bool
  var agentStalled: bool
  var holeUnnamed: bool
  var frameUnrelayed: bool

  val inHand: int = if (holding and not(ledgerDone)) 1 else 0

  action holdAgent = all { produced' = produced, pipeLen' = pipeLen }
  action holdHand = all {
    holding' = holding, relayDone' = relayDone, ledgerDone' = ledgerDone,
  }
  action holdSinks = all { consoleLen' = consoleLen, journalLen' = journalLen }
  action holdLedger = all {
    ledgered' = ledgered, dropped' = dropped, relayDropped' = relayDropped,
    gapHeld' = gapHeld, gapNamed' = gapNamed, gapLost' = gapLost,
  }
  action holdCrash = all { crashed' = crashed, recordsLost' = recordsLost }
  action holdWitness = all {
    loopWaited' = loopWaited,
    agentStalled' = agentStalled,
    holeUnnamed' = holeUnnamed,
    frameUnrelayed' = frameUnrelayed,
  }

  action init = all {
    produced' = 0, pipeLen' = 0,
    holding' = false, relayDone' = false, ledgerDone' = false,
    consoleLen' = 0, journalLen' = 0,
    ledgered' = 0, dropped' = 0, relayDropped' = 0,
    gapHeld' = 0, gapNamed' = 0, gapLost' = 0,
    crashed' = false, recordsLost' = 0,
    loopWaited' = false, agentStalled' = false,
    holeUnnamed' = false, frameUnrelayed' = false,
  }

  action agentEmit = all {
    not(crashed),
    produced < maxRecords,
    pipeLen < pipeCap,
    produced' = produced + 1,
    pipeLen' = pipeLen + 1,
    holdHand, holdSinks, holdLedger, holdCrash, holdWitness,
  }

  // The agent has a record and the pipe has no room. It is stopped here until
  // the loop reads, which is the only backpressure the design intends.
  action agentStall = all {
    not(crashed),
    produced < maxRecords,
    pipeLen == pipeCap,
    holdAgent, holdHand, holdSinks, holdLedger, holdCrash,
    loopWaited' = loopWaited,
    agentStalled' = true,
    holeUnnamed' = holeUnnamed,
    frameUnrelayed' = frameUnrelayed,
  }

  action loopRead = all {
    not(crashed),
    not(holding),
    pipeLen > 0,
    produced' = produced,
    pipeLen' = pipeLen - 1,
    holding' = true, relayDone' = false, ledgerDone' = false,
    holdSinks, holdLedger, holdCrash, holdWitness,
  }

  action loopRelay = all {
    not(crashed),
    holding,
    not(relayDone),
    consoleLen < consoleCap,
    consoleLen' = consoleLen + 1,
    journalLen' = journalLen,
    holding' = holding, relayDone' = true, ledgerDone' = ledgerDone,
    holdAgent, holdLedger, holdCrash, holdWitness,
  }

  // The console socket has no room, so the frame is dropped for the watchers
  // and counted. A watcher recovers by asking the agent for the transcript
  // (ADR-026 point 3); the agent recovers from nothing, which is why the loop
  // does not wait here.
  action loopRelayRefused = all {
    not(crashed),
    holding,
    not(relayDone),
    consoleLen == consoleCap,
    holding' = holding, relayDone' = true, ledgerDone' = ledgerDone,
    relayDropped' = relayDropped + 1,
    ledgered' = ledgered, dropped' = dropped,
    gapHeld' = gapHeld, gapNamed' = gapNamed, gapLost' = gapLost,
    holdAgent, holdSinks, holdCrash,
    loopWaited' = loopWaited,
    agentStalled' = agentStalled,
    holeUnnamed' = holeUnnamed,
    frameUnrelayed' = true,
  }

  action loopLedger = all {
    not(crashed),
    holding,
    not(ledgerDone),
    journalLen < journalCap,
    journalLen' = journalLen + 1,
    consoleLen' = consoleLen,
    holding' = holding, relayDone' = relayDone, ledgerDone' = true,
    ledgered' = ledgered + 1,
    dropped' = dropped, relayDropped' = relayDropped, gapHeld' = gapHeld,
    gapNamed' = gapNamed, gapLost' = gapLost,
    holdAgent, holdCrash, holdWitness,
  }

  // Point 7: a refused write is counted and the loop moves on. The count is in
  // the loop and not yet in the ledger, because naming it needs the slot that
  // was just refused.
  action loopLedgerRefused = all {
    not(crashed),
    holding,
    not(ledgerDone),
    journalLen == journalCap,
    holding' = holding, relayDone' = relayDone, ledgerDone' = true,
    dropped' = dropped + 1,
    gapHeld' = gapHeld + 1,
    ledgered' = ledgered, relayDropped' = relayDropped,
    gapNamed' = gapNamed, gapLost' = gapLost,
    holdAgent, holdSinks, holdCrash,
    loopWaited' = loopWaited,
    agentStalled' = agentStalled,
    holeUnnamed' = true,
    frameUnrelayed' = frameUnrelayed,
  }

  action loopFinish = all {
    not(crashed),
    holding,
    relayDone,
    ledgerDone,
    holding' = false, relayDone' = false, ledgerDone' = false,
    holdAgent, holdSinks, holdLedger, holdCrash, holdWitness,
  }

  // The gap the loop is holding reaches the ledger the moment there is room
  // for it, as one entry naming however many were refused.
  action announceGap = all {
    not(crashed),
    gapHeld > 0,
    journalLen < journalCap,
    journalLen' = journalLen + 1,
    consoleLen' = consoleLen,
    gapNamed' = gapNamed + gapHeld,
    gapHeld' = 0,
    ledgered' = ledgered, dropped' = dropped,
    relayDropped' = relayDropped, gapLost' = gapLost,
    holdAgent, holdHand, holdCrash, holdWitness,
  }

  action journalDrain = all {
    journalLen > 0,
    journalLen' = journalLen - 1,
    consoleLen' = consoleLen,
    holdAgent, holdHand, holdLedger, holdCrash, holdWitness,
  }

  action consoleDrain = all {
    consoleLen > 0,
    consoleLen' = consoleLen - 1,
    journalLen' = journalLen,
    holdAgent, holdHand, holdLedger, holdCrash, holdWitness,
  }

  // The unit dies, taking the loop and the agent with it (ADR-026 point 10).
  // Whatever the loop was holding in memory dies with it.
  action loopCrash = all {
    not(crashed),
    crashed' = true,
    recordsLost' = recordsLost + pipeLen + inHand,
    produced' = produced,
    pipeLen' = 0,
    holding' = false, relayDone' = false, ledgerDone' = false,
    gapLost' = gapLost + gapHeld,
    gapHeld' = 0,
    ledgered' = ledgered, dropped' = dropped,
    relayDropped' = relayDropped, gapNamed' = gapNamed,
    holdSinks, holdWitness,
  }

  action step = any {
    agentEmit, agentStall,
    loopRead, loopRelay, loopRelayRefused,
    loopLedger, loopLedgerRefused, loopFinish,
    announceGap, journalDrain, consoleDrain,
    loopCrash,
  }

  // Point 7. The tap is in line with the pipe, so anything it waits for the
  // agent waits for too. Both sinks, because one blocking sink is enough.
  val theTapNeverWaits: bool = not(loopWaited)

  // No record leaves the pipe without a disposition. Bookkeeping, so that a
  // violation of the two below is a design fault and not an arithmetic one.
  val nothingVanishes: bool =
    produced == pipeLen + inHand + ledgered + dropped + recordsLost

  // Every refusal is somewhere: named in the ledger, held by the loop for the
  // next slot, or lost with the loop. The third disjunct is what a crash costs.
  val everyRefusalIsAccounted: bool = dropped == gapNamed + gapHeld + gapLost

  // A watcher that missed a frame costs the ledger nothing, because the two
  // sinks are refused independently and the record's ledger entry is written
  // whatever the console did with its copy.
  val aDroppedFrameCostsTheLedgerNothing: bool =
    relayDropped == 0 or ledgered + dropped + recordsLost + pipeLen + inHand == produced

  val allInvariants: bool = and {
    theTapNeverWaits,
    nothingVanishes,
    everyRefusalIsAccounted,
    aDroppedFrameCostsTheLedgerNothing,
  }

  // Witness, stated as a negation so a violation is the evidence: the journal
  // queue can fill while the loop holds a record. A model where this never
  // violates never exercises point 7 at all.
  val neverRefused: bool = not(holeUnnamed)

  // Witness: the agent can be stopped by a pipe the loop has not drained. This
  // is the backpressure the design keeps, as against the one point 7 removes.
  val neverStalled: bool = not(agentStalled)

  // Witness: the console can lose a frame. A model where this never violates
  // is not exercising the widened half of point 7.
  val neverRelayRefused: bool = not(frameUnrelayed)

  // A hole nobody can find. The ledger says nothing was refused and records
  // are missing anyway. This is not in allInvariants: it violates, the trace
  // is a loop that dies holding a gap, and the Consequences section of
  // ADR-027 records it rather than repairing it.
  val noSilentHoleFromACrash: bool = gapLost == 0
}
