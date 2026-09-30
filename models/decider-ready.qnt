// Who the decider believes is ready, against who the executor does.
// Constrains factory/src/decider/bind.ts (the ready set and the snapshot
// it dedupes on) and the board event factory/src/executor/main.ts
// publishes.
//
// One issue, one role that provides its stage. The executor keeps the
// ready set and refuses an assign to a role not in it; it restarts with
// an empty set, and the role announces ready again. The decider thinks
// only about a snapshot unlike the last one it thought about, and that
// memory outlives its process. The question is whether the factory can
// stop: the issue open, the role ready by the executor's reckoning, and
// nothing left that would make the decider think again.
//
// mode is how the decider learns who is ready:
//   "replay"  every role's control stream from the start, as it did
//             until 2026-09-30, when a run on the host stopped this way
//   "board"   the ready set of the executor's latest board event
//   "epoch"   the same, with the executor's start in the board event
module deciderReady {
  pure val MAX_EPOCH = 2
  var mode: str
  var epoch: int          // the executor's starts
  var execReady: bool     // the role is in the executor's ready set
  var replayReady: bool   // a replay of the control stream says ready
  var boardReady: bool    // the latest board event's ready set
  var boardEpoch: int     // the latest board event's executor start
  var viewReady: bool     // what the decider holds
  var viewEpoch: int
  var assigned: bool
  var inflight: bool      // an assign on the commands stream, unapplied
  var lastReady: bool     // the snapshot last thought about
  var lastEpoch: int
  var lastAssigned: bool
  var thoughtOnce: bool

  action init = all {
    nondet m = Set("replay", "board", "epoch").oneOf()
    mode' = m,
    epoch' = 1,
    // An earlier executor's run left the role's ready on its stream.
    execReady' = false,
    replayReady' = true,
    boardReady' = false,
    boardEpoch' = 0,
    viewReady' = false,
    viewEpoch' = 0,
    assigned' = false,
    inflight' = false,
    lastReady' = false,
    lastEpoch' = 0,
    lastAssigned' = false,
    thoughtOnce' = false,
  }

  action unchangedDecider = all {
    viewReady' = viewReady, viewEpoch' = viewEpoch,
    lastReady' = lastReady, lastEpoch' = lastEpoch,
    lastAssigned' = lastAssigned, thoughtOnce' = thoughtOnce,
  }

  // The executor starts again: its ready set is empty.
  action executorRestart = all {
    epoch < MAX_EPOCH, not(assigned),
    mode' = mode, epoch' = epoch + 1, execReady' = false,
    replayReady' = replayReady, boardReady' = boardReady, boardEpoch' = boardEpoch,
    assigned' = assigned, inflight' = inflight,
    unchangedDecider,
  }

  // The role's session announces ready on its control stream.
  action roleAnnounce = all {
    not(execReady), not(assigned),
    mode' = mode, epoch' = epoch, execReady' = true,
    replayReady' = true, boardReady' = boardReady, boardEpoch' = boardEpoch,
    assigned' = assigned, inflight' = inflight,
    unchangedDecider,
  }

  // The executor publishes its board, every ten seconds.
  action publishBoard = all {
    mode' = mode, epoch' = epoch, execReady' = execReady,
    replayReady' = replayReady, boardReady' = execReady, boardEpoch' = epoch,
    assigned' = assigned, inflight' = inflight,
    unchangedDecider,
  }

  // The decider reads what it learns ready from, in a running process or
  // a fresh one: its memory of the last snapshot is kept either way.
  action observe = all {
    mode' = mode, epoch' = epoch, execReady' = execReady,
    replayReady' = replayReady, boardReady' = boardReady, boardEpoch' = boardEpoch,
    assigned' = assigned, inflight' = inflight,
    viewReady' = if (mode == "replay") replayReady else boardReady,
    viewEpoch' = if (mode == "epoch") boardEpoch else 0,
    lastReady' = lastReady, lastEpoch' = lastEpoch,
    lastAssigned' = lastAssigned, thoughtOnce' = thoughtOnce,
  }

  val unlikeLast = not(thoughtOnce) or viewReady != lastReady or viewEpoch != lastEpoch or assigned != lastAssigned

  // The decider thinks about a snapshot unlike the last, and assigns the
  // issue to the role when it holds the role ready.
  action think = all {
    unlikeLast, not(inflight),
    mode' = mode, epoch' = epoch, execReady' = execReady,
    replayReady' = replayReady, boardReady' = boardReady, boardEpoch' = boardEpoch,
    assigned' = assigned,
    inflight' = viewReady and not(assigned),
    viewReady' = viewReady, viewEpoch' = viewEpoch,
    lastReady' = viewReady, lastEpoch' = viewEpoch,
    lastAssigned' = assigned, thoughtOnce' = true,
  }

  // The executor applies the assign: to a ready role it is sent and acked,
  // which takes the role out of every ready set; otherwise refused.
  action apply = all {
    inflight,
    mode' = mode, epoch' = epoch,
    execReady' = false,
    replayReady' = if (execReady) false else replayReady,
    boardReady' = boardReady, boardEpoch' = boardEpoch,
    assigned' = execReady,
    inflight' = false,
    unchangedDecider,
  }

  action step = any { executorRestart, roleAnnounce, publishBoard, observe, think, apply }

  // Nothing left would move the factory: the executor holds the role
  // ready, its board and the decider's view say what they will go on
  // saying, and the decider has already thought about that snapshot.
  val settledView = viewReady == (if (mode == "replay") replayReady else boardReady)
    and viewEpoch == (if (mode == "epoch") boardEpoch else 0)
  val stuck = not(assigned) and not(inflight) and execReady
    and boardReady == execReady and boardEpoch == epoch
    and settledView and thoughtOnce and not(unlikeLast)

  val replayNeverStuck = mode == "replay" implies not(stuck)
  val boardNeverStuck = mode == "board" implies not(stuck)
  val epochNeverStuck = mode == "epoch" implies not(stuck)
  // A witness, violated as it must be: with the epoch the issue does get
  // assigned, so epochNeverStuck is not passing on a model that cannot.
  val epochNeverAssigns = mode == "epoch" implies not(assigned)
  val allInvariants = epochNeverStuck
}
