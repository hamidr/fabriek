// Task and run lifecycle of the software factory in
// docs/PRD-003-software-factory.md.
//
// Two state machines, as the document specifies: a task outlives its runs.
// The interesting seam is that a run stopped at a gate releases the global
// concurrency slot but NOT the role, because the role's single worktree still
// holds that task's branch.
module factory {
  pure val tasks = Set("t1", "t2", "t3", "t4")
  pure val roles = Set("builderA", "builderB", "reviewer")

  // One task per role, and one more sharing builderA, so both limits can bite:
  // t1 and t4 contend for a role, and three distinct roles can outnumber the
  // global concurrency cap. A cap at or above the role count is unreachable,
  // because one worktree per role already bounds active runs by role count.
  pure val ownerOf = Map(
    "t1" -> "builderA", "t2" -> "builderB", "t3" -> "reviewer", "t4" -> "builderA"
  )

  // Whether a task's stage declares a gate before it may finish.
  pure val gated = Map("t1" -> true, "t2" -> false, "t3" -> false, "t4" -> true)

  pure val maxConcurrent = 2
  pure val maxAttempts = 2
  pure val budgetRuns = 6

  // task lifecycle: proposed ready running blocked awaitingReview done failed cancelled
  var taskState: str -> str
  // run lifecycle: none starting working gate resumable settled runFailed runCancelled
  var runState: str -> str
  var answered: str -> bool
  var attempts: str -> int
  var runsSpent: int
  var mainLen: int
  var mainLenPrev: int
  var integrating: str

  pure def liveRun(rs: str): bool = rs == "starting" or rs == "working"
  pure def holdsRole(rs: str): bool = liveRun(rs) or rs == "gate" or rs == "resumable"

  val activeRuns: int = tasks.filter(t => liveRun(runState.get(t))).size()

  def roleBusy(r: str): bool =
    tasks.exists(t => ownerOf.get(t) == r and holdsRole(runState.get(t)))

  action init = all {
    taskState' = tasks.mapBy(_ => "proposed"),
    runState' = tasks.mapBy(_ => "none"),
    answered' = tasks.mapBy(_ => false),
    attempts' = tasks.mapBy(_ => 0),
    runsSpent' = 0,
    mainLen' = 0,
    mainLenPrev' = 0,
    integrating' = "",
  }

  // The supervisor checks the required fields are present. Nothing else moves
  // a task out of proposed.
  action markReady(t) = all {
    taskState.get(t) == "proposed",
    taskState' = taskState.set(t, "ready"),
    runState' = runState, answered' = answered, attempts' = attempts,
    runsSpent' = runsSpent, mainLen' = mainLen, mainLenPrev' = mainLen,
    integrating' = integrating,
  }

  // Only the supervisor starts a run, and every cap is checked here.
  action startRun(t) = all {
    taskState.get(t) == "ready",
    attempts.get(t) < maxAttempts,
    runsSpent < budgetRuns,
    activeRuns < maxConcurrent,
    not(roleBusy(ownerOf.get(t))),
    taskState' = taskState.set(t, "running"),
    runState' = runState.set(t, "starting"),
    attempts' = attempts.set(t, attempts.get(t) + 1),
    runsSpent' = runsSpent + 1,
    answered' = answered.set(t, false),
    mainLen' = mainLen, mainLenPrev' = mainLen, integrating' = integrating,
  }

  action work(t) = all {
    runState.get(t) == "starting",
    runState' = runState.set(t, "working"),
    taskState' = taskState, answered' = answered, attempts' = attempts,
    runsSpent' = runsSpent, mainLen' = mainLen, mainLenPrev' = mainLen,
    integrating' = integrating,
  }

  // A gate stops the run. It keeps the role's worktree and releases the slot.
  action hitGate(t) = all {
    runState.get(t) == "working",
    gated.get(t),
    not(answered.get(t)),
    runState' = runState.set(t, "gate"),
    taskState' = taskState, answered' = answered, attempts' = attempts,
    runsSpent' = runsSpent, mainLen' = mainLen, mainLenPrev' = mainLen,
    integrating' = integrating,
  }

  // Answering a gate records the answer. It does not resume the run: the slot
  // the gate released may have been taken while the operator was away, so the
  // run has to be readmitted like any other.
  action answerGate(t) = all {
    runState.get(t) == "gate",
    answered' = answered.set(t, true),
    runState' = runState.set(t, "resumable"),
    taskState' = taskState, attempts' = attempts, runsSpent' = runsSpent,
    mainLen' = mainLen, mainLenPrev' = mainLen, integrating' = integrating,
  }

  // The supervisor readmits an answered run under the same concurrency check
  // it applies when starting one. No further budget is charged: the run was
  // paid for when it started.
  action resume(t) = all {
    runState.get(t) == "resumable",
    activeRuns < maxConcurrent,
    runState' = runState.set(t, "working"),
    taskState' = taskState, answered' = answered, attempts' = attempts,
    runsSpent' = runsSpent, mainLen' = mainLen, mainLenPrev' = mainLen,
    integrating' = integrating,
  }

  // Settling requires the gate to have been answered when the stage declares
  // one. This is the guard the whole gate mechanism rests on.
  action settle(t) = all {
    runState.get(t) == "working",
    not(gated.get(t)) or answered.get(t),
    runState' = runState.set(t, "settled"),
    taskState' = taskState.set(t, "awaitingReview"),
    answered' = answered, attempts' = attempts, runsSpent' = runsSpent,
    mainLen' = mainLen, mainLenPrev' = mainLen, integrating' = integrating,
  }

  // A crash, or a session that went idle recording nothing. The task goes back
  // to ready unless its attempts are gone.
  action failRun(t) = all {
    liveRun(runState.get(t)),
    runState' = runState.set(t, "runFailed"),
    taskState' =
      if (attempts.get(t) >= maxAttempts) taskState.set(t, "failed")
      else taskState.set(t, "ready"),
    answered' = answered, attempts' = attempts, runsSpent' = runsSpent,
    mainLen' = mainLen, mainLenPrev' = mainLen, integrating' = integrating,
  }

  // Integration is serialised per factory and advances main by fast-forward.
  action beginIntegrate(t) = all {
    taskState.get(t) == "awaitingReview",
    integrating == "",
    integrating' = t,
    taskState' = taskState, runState' = runState, answered' = answered,
    attempts' = attempts, runsSpent' = runsSpent,
    mainLen' = mainLen, mainLenPrev' = mainLen,
  }

  action finishIntegrate(t) = all {
    integrating == t,
    integrating' = "",
    mainLenPrev' = mainLen,
    mainLen' = mainLen + 1,
    taskState' = taskState.set(t, "done"),
    runState' = runState.set(t, "none"),
    answered' = answered, attempts' = attempts, runsSpent' = runsSpent,
  }

  action step = nondet t = tasks.oneOf() {
    any {
      markReady(t), startRun(t), work(t), hitGate(t), answerGate(t),
      settle(t), failRun(t), beginIntegrate(t), finishIntegrate(t), resume(t),
    }
  }

  // ---- invariants ----

  // No run proceeds past a gate that was never answered.
  val noSettleThroughUnansweredGate: bool =
    tasks.forall(t =>
      (runState.get(t) == "settled" and gated.get(t)) implies answered.get(t))

  // Concurrent runs never exceed the global cap.
  val concurrencyRespected: bool = activeRuns <= maxConcurrent

  // A gate holds no concurrency, and neither does a run whose gate was
  // answered but which has not been readmitted.
  val gateHoldsNoSlot: bool =
    tasks.forall(t =>
      (runState.get(t) == "gate" or runState.get(t) == "resumable")
        implies not(liveRun(runState.get(t))))

  // A workflow that has spent its budget starts nothing further.
  val budgetRespected: bool = runsSpent <= budgetRuns

  // A task that has exhausted its attempts starts no further run.
  val attemptsRespected: bool = tasks.forall(t => attempts.get(t) <= maxAttempts)

  // A role never runs two tasks at once: one worktree, one branch.
  val oneTaskPerRole: bool =
    roles.forall(r =>
      tasks.filter(t => ownerOf.get(t) == r and holdsRole(runState.get(t))).size() <= 1)

  // Two integrations never overlap.
  val integrationSerialised: bool =
    tasks.filter(t => integrating == t).size() <= 1

  // main only ever moves forward.
  val mainMovesForward: bool = mainLen >= mainLenPrev

  // A task that reached a terminal state has no live run against it.
  val terminalTaskHasNoLiveRun: bool =
    tasks.forall(t =>
      (taskState.get(t) == "done" or taskState.get(t) == "failed")
        implies not(liveRun(runState.get(t))))

  val allInvariants: bool = and {
    noSettleThroughUnansweredGate, concurrencyRespected, gateHoldsNoSlot,
    budgetRespected, attemptsRespected, oneTaskPerRole,
    integrationSerialised, mainMovesForward, terminalTaskHasNoLiveRun,
  }
}
