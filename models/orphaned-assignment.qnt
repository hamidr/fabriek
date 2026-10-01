// An assignment whose role started again without it. Constrains
// factory/src/executor/core.ts: heard, settle and checkOutcomes, and the
// order the loop in factory/src/extension/actor.ts says things in.
//
// One issue, one role. The executor assigns only to a role in its ready
// set, marks the row assigning, and sends; the role acks and works; it
// comments its outcome and then its process ends, and the next process
// announces ready. A session can end at any moment (the executor ends
// every session when it stops), and the next process announces ready
// holding nothing. The executor reads the role's control stream in order,
// in batches, in the order the role said it.
//
// mode is what a ready does to a row assigned to the role:
//   "keep"  nothing, as until 2026-10-01: a row whose role started again
//           stays assigned with nobody working it
//   "free"  the row is freed when no outcome follows its attempt
module orphanedAssignment {
  var mode: str
  var board: str        // "open", "assigning", "assigned"
  var outcome: bool     // an outcome comment after the attempt's line
  var role: str         // "idle", "working"
  var mailbox: bool     // an assignment sent and not yet taken
  var stream: List[str] // the role's control stream, unread by the executor
  var execReady: bool
  var abandoned: int    // rows freed by a ready, to see the rule fire

  action init = all {
    nondet m = Set("keep", "free").oneOf()
    mode' = m,
    board' = "open",
    outcome' = false,
    role' = "idle",
    mailbox' = false,
    stream' = ["ready"],
    execReady' = false,
    abandoned' = 0,
  }

  // The executor assigns the open issue to the role it holds ready.
  action route = all {
    board == "open", execReady, not(outcome),
    mode' = mode, board' = "assigning", outcome' = outcome, role' = role,
    mailbox' = true, stream' = stream, execReady' = false, abandoned' = abandoned,
  }

  // The role takes the assignment from its mailbox and acks it.
  action take = all {
    mailbox, role == "idle", stream.length() < 4,
    mode' = mode, board' = board, outcome' = outcome, role' = "working",
    mailbox' = false, stream' = stream.append("ack"), execReady' = execReady, abandoned' = abandoned,
  }

  // The role reports: the comment first, then its process ends and the
  // next one announces ready.
  action finish = all {
    role == "working", stream.length() < 4,
    mode' = mode, board' = board, outcome' = true, role' = "idle",
    mailbox' = mailbox, stream' = stream.append("ready"), execReady' = execReady, abandoned' = abandoned,
  }

  // The session ends with no outcome; the next process holds nothing. An
  // assignment still in the mailbox is read from where the reader starts,
  // so it may be lost with the session.
  action crash = all {
    stream.length() < 4,
    nondet keepMail = Set(true, false).oneOf()
    all {
      mode' = mode, board' = board, outcome' = outcome, role' = "idle",
      mailbox' = (mailbox and keepMail), stream' = stream.append("ready"),
      execReady' = execReady, abandoned' = abandoned,
    }
  }

  // The executor reads a batch off the front of the stream and applies it
  // in the order the role said it: an ack moves assigning to assigned; a
  // ready puts the role in the ready set and, in mode free, frees a row
  // already assigned to it with no outcome. Applying a batch's acks before
  // its readies instead frees the work a stale ready preceded: the first
  // run of this model found that trace.
  action read = all {
    stream.length() > 0,
    nondet n = 1.to(stream.length()).oneOf()
    val batch = stream.slice(0, n)
    val applied = batch.foldl({ board: board, ready: execReady, freed: 0 }, (s, x) =>
      if (x == "ack")
        { ...s, board: if (s.board == "assigning") "assigned" else s.board }
      else if (mode == "free" and s.board == "assigned" and not(outcome))
        { board: "open", ready: true, freed: s.freed + 1 }
      else
        { ...s, ready: true })
    all {
      mode' = mode,
      board' = applied.board,
      outcome' = outcome, role' = role, mailbox' = mailbox,
      stream' = stream.slice(n, stream.length()),
      execReady' = applied.ready,
      abandoned' = abandoned + applied.freed,
    }
  }

  // checkOutcomes: an outcome after the attempt moves the row on, here
  // back to open for the next stage.
  action judge = all {
    board == "assigned", outcome,
    mode' = mode, board' = "open", outcome' = false, role' = role,
    mailbox' = mailbox, stream' = stream, execReady' = execReady, abandoned' = abandoned,
  }

  action step = any { route, take, finish, crash, read, judge }

  // The executor never frees a row its role is working: the work and its
  // outcome would land on an issue another assignment may already hold.
  val neverFreesLiveWork = not(board == "open" and role == "working" and not(outcome))

  // Nothing left would move the row: assigned, no outcome, the role idle
  // with nothing in its mailbox, and everything it said already read.
  val orphaned = board == "assigned" and not(outcome) and role == "idle"
    and not(mailbox) and stream.length() == 0
  val keepNeverOrphans = mode == "keep" implies not(orphaned)
  val freeNeverOrphans = mode == "free" implies not(orphaned)

  // A witness, violated as it must be: the rule does fire.
  val freeNeverAbandons = mode == "free" implies abandoned == 0

  val allInvariants = neverFreesLiveWork and freeNeverOrphans
}
