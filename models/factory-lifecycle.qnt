// Task and run lifecycle of the software factory in
// docs/PRD-003-software-factory.md.
//
// Two state machines, as the document specifies: a task outlives its runs.
// The interesting seam is that a run stopped at a gate releases the global
// concurrency slot but NOT the role, because the role's single worktree still
// holds that task's branch.
module factory {
  // tc is the consult t1 may raise. It does not exist until t1 asks for it.
  pure val tasks = Set("t1", "t2", "t3", "t4", "tc")
  pure val roles = Set("builderA", "builderB", "reviewer", "architect")

  // ADR-015: a stage names a capability and a role declares what it provides,
  // so who works a task is resolved when it is taken rather than fixed by the
  // pipeline. Two roles provide "build", which is what makes fan-out
  // parallelise and what makes one-task-per-role a property of the taking rule
  // rather than of a table written in advance.
  pure val needsOf = Map(
    "t1" -> "build", "t2" -> "build", "t3" -> "review",
    "t4" -> "build", "tc" -> "design"
  )
  pure val providesOf = Map(
    "builderA" -> Set("build"),
    "builderB" -> Set("build"),
    "reviewer" -> Set("review"),
    "architect" -> Set("design")
  )
  // Declaration order: among idle capable roles the first takes the task, so a
  // factory replays the same way twice.
  pure val roleOrder = ["builderA", "builderB", "reviewer", "architect"]

  // Whether a task's stage declares a gate before it may finish.
  pure val gated = Map(
    "t1" -> true, "t2" -> false, "t3" -> false, "t4" -> true, "tc" -> false
  )

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
  // Which role took a task. Empty until it is taken, and never changed after:
  // every later attempt goes to the role whose namespace holds the branch.
  var takenBy: str -> str
  // Every role a task has actually run on. Stickiness is a claim about the
  // history rather than about one field, so the history is kept: a taking rule
  // that quietly reassigned a retry would leave two roles here.
  var ranOn: str -> Set[str]

  pure def liveRun(rs: str): bool = rs == "starting" or rs == "working"
  pure def holdsRole(rs: str): bool = liveRun(rs) or rs == "gate" or rs == "resumable"

  val activeRuns: int = tasks.filter(t => liveRun(runState.get(t))).size()

  // A role's worktree is held by a task that is running, waiting at a gate,
  // waiting to be readmitted, or blocked on a consult. A blocked task keeps
  // its role rather than freeing it: nothing is committed and nothing switches
  // branches, so a role's worktree always holds exactly the task it is
  // working. The cost is idle time, which is measurable, rather than a new
  // failure mode, which would not be.
  def occupies(t: str): bool = or {
    holdsRole(runState.get(t)),
    taskState.get(t) == "blocked",
    taskState.get(t) == "unblocked",
  }

  def roleBusy(r: str): bool =
    tasks.exists(t => takenBy.get(t) == r and occupies(t))

  def canDo(r: str, cap: str): bool = providesOf.get(r).contains(cap)

  // The role that would take a task now: the first idle capable one in
  // declaration order, or "" when every capable role is busy.
  def takerFor(t: str): str =
    roleOrder.foldl("", (acc, r) =>
      if (acc != "") acc
      else if (canDo(r, needsOf.get(t)) and not(roleBusy(r))) r
      else "")

  action init = all {
    // tc does not exist until it is asked for.
    taskState' = tasks.mapBy(t => if (t == "tc") "unborn" else "proposed"),
    runState' = tasks.mapBy(_ => "none"),
    answered' = tasks.mapBy(_ => false),
    attempts' = tasks.mapBy(_ => 0),
    runsSpent' = 0,
    takenBy' = tasks.mapBy(_ => ""),
    ranOn' = tasks.mapBy(_ => Set()),
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
    takenBy' = takenBy,
    ranOn' = ranOn,
  }

  // Only the supervisor starts a run, and every cap is checked here.
  // A task never taken resolves its capability to a role now; a task already
  // taken waits for that role and no other, because its branch is in that
  // role's namespace and no peer can write it.
  action startRun(t) = all {
    taskState.get(t) == "ready",
    attempts.get(t) < maxAttempts,
    runsSpent < budgetRuns,
    activeRuns < maxConcurrent,
    if (takenBy.get(t) == "") takerFor(t) != ""
    else not(roleBusy(takenBy.get(t))),
    takenBy' =
      if (takenBy.get(t) == "") takenBy.set(t, takerFor(t)) else takenBy,
    ranOn' =
      if (takenBy.get(t) == "") ranOn.set(t, ranOn.get(t).union(Set(takerFor(t))))
      else ranOn.set(t, ranOn.get(t).union(Set(takenBy.get(t)))),
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
    takenBy' = takenBy,
    ranOn' = ranOn,
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
    takenBy' = takenBy,
    ranOn' = ranOn,
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
    takenBy' = takenBy,
    ranOn' = ranOn,
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
    takenBy' = takenBy,
    ranOn' = ranOn,
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
    takenBy' = takenBy,
    ranOn' = ranOn,
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
    takenBy' = takenBy,
    ranOn' = ranOn,
  }

  // Integration is serialised per factory and advances main by fast-forward.
  action beginIntegrate(t) = all {
    taskState.get(t) == "awaitingReview",
    integrating == "",
    integrating' = t,
    taskState' = taskState, runState' = runState, answered' = answered,
    attempts' = attempts, runsSpent' = runsSpent,
    mainLen' = mainLen, mainLenPrev' = mainLen,
    takenBy' = takenBy,
    ranOn' = ranOn,
  }

  action finishIntegrate(t) = all {
    integrating == t,
    integrating' = "",
    mainLenPrev' = mainLen,
    mainLen' = mainLen + 1,
    taskState' = taskState.set(t, "done"),
    runState' = runState.set(t, "none"),
    answered' = answered, attempts' = attempts, runsSpent' = runsSpent,
    takenBy' = takenBy,
    ranOn' = ranOn,
  }

  // t1 asks the architect. The consult is created, t1 blocks, and the turn
  // that was running ends. A consult is a leaf: tc can ask nobody.
  action askConsult(t) = all {
    t == "t1",
    taskState.get("t1") == "running",
    taskState.get("tc") == "unborn",
    taskState' = taskState.set("t1", "blocked").set("tc", "proposed"),
    runState' = runState.set("t1", "none"),
    answered' = answered, attempts' = attempts, runsSpent' = runsSpent,
    mainLen' = mainLen, mainLenPrev' = mainLen, integrating' = integrating,
    takenBy' = takenBy,
    ranOn' = ranOn,
  }

  // The consult reached a terminal state, so the asker may go again. It is not
  // resumed here: it released its slot while it waited, exactly as a gate does.
  action consultResolved(t) = all {
    t == "t1",
    taskState.get("t1") == "blocked",
    taskState.get("tc") == "done" or taskState.get("tc") == "failed",
    taskState' = taskState.set("t1", "unblocked"),
    runState' = runState, answered' = answered, attempts' = attempts,
    runsSpent' = runsSpent, mainLen' = mainLen, mainLenPrev' = mainLen,
    integrating' = integrating,
    takenBy' = takenBy,
    ranOn' = ranOn,
  }

  action readmitUnblocked(t) = all {
    taskState.get(t) == "unblocked",
    takenBy.get(t) != "",
    activeRuns < maxConcurrent,
    taskState' = taskState.set(t, "running"),
    runState' = runState.set(t, "working"),
    answered' = answered, attempts' = attempts, runsSpent' = runsSpent,
    mainLen' = mainLen, mainLenPrev' = mainLen, integrating' = integrating,
    takenBy' = takenBy,
    ranOn' = ranOn,
  }

  action step = nondet t = tasks.oneOf() {
    any {
      markReady(t), startRun(t), work(t), hitGate(t), answerGate(t),
      settle(t), failRun(t), beginIntegrate(t), finishIntegrate(t), resume(t),
      askConsult(t), consultResolved(t), readmitUnblocked(t),
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
      tasks.filter(t => takenBy.get(t) == r and holdsRole(runState.get(t))).size() <= 1)

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

  // A consult is a leaf, so it never waits on anything and no set of tasks can
  // wait on each other in a cycle.
  val consultNeverBlocks: bool =
    taskState.get("tc") != "blocked" and taskState.get("tc") != "unblocked"

  // A task that stopped being blocked is readmitted, not resumed: while it is
  // unblocked it holds no concurrency slot.
  val unblockedHoldsNoSlot: bool =
    tasks.forall(t =>
      taskState.get(t) == "unblocked" implies not(liveRun(runState.get(t))))

  // ADR-015 decision 1: work only reaches a role that declared it can do it.
  val takerProvidesCapability: bool =
    tasks.forall(t =>
      takenBy.get(t) != "" implies canDo(takenBy.get(t), needsOf.get(t)))

  // ADR-015 decision 4: a task sticks to the role that took it, so every
  // attempt at it was made by the same role however many there were.
  val attemptsStayWithOneRole: bool =
    tasks.forall(t => ranOn.get(t).size() <= 1)

  // A retried task never moves to an idle peer providing the same capability.
  val retryNeverMovesToAPeer: bool =
    tasks.forall(t =>
      (attempts.get(t) > 1 and takenBy.get(t) != "")
        implies ranOn.get(t) == Set(takenBy.get(t)))

  // Fan-out has to be able to parallelise, or this is the pipeline it
  // replaces. Stated as a negation on purpose: a violation IS the witness, and
  // a model where this never violates would be modelling the old behaviour.
  val neverTwoOfOneCapabilityAtOnce: bool =
    not(tasks.exists(a => tasks.exists(b => and {
      a != b,
      needsOf.get(a) == needsOf.get(b),
      liveRun(runState.get(a)),
      liveRun(runState.get(b)),
      takenBy.get(a) != takenBy.get(b),
    })))

  val allInvariants: bool = and {
    takerProvidesCapability, attemptsStayWithOneRole, retryNeverMovesToAPeer,
    consultNeverBlocks, unblockedHoldsNoSlot,
    noSettleThroughUnansweredGate, concurrencyRespected, gateHoldsNoSlot,
    budgetRespected, attemptsRespected, oneTaskPerRole,
    integrationSerialised, mainMovesForward, terminalTaskHasNoLiveRun,
  }
}
