// Taking a task in the software factory, as decided in
// docs/ADR-023-a-leased-claim-takes-a-task.md and required by phase 2 of
// docs/PRD-005-agents-that-take-their-own-work.md.
//
// The design has no lock server. Several agents in separate cages share one
// git repository, and the only atomic thing between them is a ref update. An
// agent takes a task by creating refs/claims/<task> with an expected old value
// of "", which git refuses if the ref exists. The claim is a lease: it carries
// a deadline, the holder renews it while working, and an expired claim may be
// taken over by any capable agent.
//
// What this model exists to check is the seam between those two sentences.
// Creating a claim is one atomic step; taking over an expired one is two, a
// guarded delete and then a create, with an arbitrary interleaving in between.
// The modelled design therefore makes a renewal move the ref to a new value,
// so that an agent which observed an expired claim and then went to delete it
// is refused if the holder renewed in the meantime. Break that (make renew
// leave refVal alone) and noLiveClaimDeleted fails, which is the whole reason
// the deadline lives in the claim rather than beside it.
module taskClaim {
  // Two agents providing one capability is the smallest configuration where
  // the race exists at all. The third provides something else and is the
  // negative control for holderProvidesCapability.
  pure val agents = Set("builderA", "builderB", "reviewer")
  pure val tasks = Set("t1", "t2")

  pure val needsOf = Map("t1" -> "build", "t2" -> "build")
  pure val providesOf = Map(
    "builderA" -> Set("build"),
    "builderB" -> Set("build"),
    "reviewer" -> Set("review")
  )

  // Short enough that expiry is reachable inside a run of a few dozen steps.
  pure val leaseLen = 2
  pure val maxClock = 8

  // refs/claims/<task>. Zero means the ref does not exist. Every claim and
  // every renewal takes a fresh value, which is what makes a guarded delete
  // able to tell a claim apart from its successor.
  var refVal: str -> int
  var holder: str -> str
  var deadline: str -> int

  var working: str -> str
  var alive: str -> bool

  // An agent that has read an expired claim and not yet acted on it. This is
  // the read-then-act window the two-step takeover opens, and modelling it is
  // the point: without it a takeover looks atomic and nothing can go wrong.
  var pendTask: str -> str
  var pendVal: str -> int

  // How many times a task has been finished. A count rather than a set,
  // because "at most once" is the property the holder guard has to deliver.
  var finishCount: str -> int
  var clock: int
  var nextVal: int

  // Witnesses. A guarded delete that removed a claim which had not expired,
  // and a takeover that happened while another live agent still believed it
  // was working the task.
  var liveClaimDeleted: bool
  var doubleWorked: bool
  var reclaimedAfterCrash: bool

  def canDo(a: str, cap: str): bool = providesOf.get(a).contains(cap)
  def expired(t: str): bool = deadline.get(t) <= clock

  action holdRefs = all {
    refVal' = refVal, holder' = holder, deadline' = deadline,
  }
  action holdAgents = all { working' = working, alive' = alive }
  action holdPend = all { pendTask' = pendTask, pendVal' = pendVal }
  action holdBooks = all {
    finishCount' = finishCount, clock' = clock, nextVal' = nextVal,
  }
  action holdWitness = all {
    liveClaimDeleted' = liveClaimDeleted,
    doubleWorked' = doubleWorked,
    reclaimedAfterCrash' = reclaimedAfterCrash,
  }

  action init = all {
    refVal' = tasks.mapBy(_ => 0),
    holder' = tasks.mapBy(_ => ""),
    deadline' = tasks.mapBy(_ => 0),
    working' = agents.mapBy(_ => ""),
    alive' = agents.mapBy(_ => true),
    pendTask' = agents.mapBy(_ => ""),
    pendVal' = agents.mapBy(_ => 0),
    finishCount' = tasks.mapBy(_ => 0),
    clock' = 0,
    nextVal' = 1,
    liveClaimDeleted' = false,
    doubleWorked' = false,
    reclaimedAfterCrash' = false,
  }

  // git update-ref refs/claims/<t> <new> "" succeeds only when the ref is
  // absent. Action atomicity is exactly the ref lock: the second agent to run
  // this finds refVal non-zero and its guard fails.
  action claimCreate(a, t) = all {
    alive.get(a),
    working.get(a) == "",
    pendTask.get(a) == "",
    canDo(a, needsOf.get(t)),
    finishCount.get(t) == 0,
    refVal.get(t) == 0,
    refVal' = refVal.set(t, nextVal),
    holder' = holder.set(t, a),
    deadline' = deadline.set(t, clock + leaseLen),
    working' = working.set(a, t),
    alive' = alive,
    holdPend,
    finishCount' = finishCount, clock' = clock, nextVal' = nextVal + 1,
    liveClaimDeleted' = liveClaimDeleted,
    // Somebody else alive still thinks it is working this task. Reachable by
    // design, since a hung holder stops renewing without stopping working.
    // The parentheses are load-bearing: x' = a or b parses as (x' = a) or b,
    // which is satisfiable without ever updating x and makes the witness lie.
    doubleWorked' = (doubleWorked or
      agents.exists(b => b != a and alive.get(b) and working.get(b) == t)),
    reclaimedAfterCrash' = reclaimedAfterCrash,
  }

  // Reading an expired claim. Nothing is written yet, and what the agent
  // remembers is the value it saw, which is what it will pass to the delete.
  action observeExpired(a, t) = all {
    alive.get(a),
    working.get(a) == "",
    pendTask.get(a) == "",
    canDo(a, needsOf.get(t)),
    finishCount.get(t) == 0,
    refVal.get(t) != 0,
    expired(t),
    pendTask' = pendTask.set(a, t),
    pendVal' = pendVal.set(a, refVal.get(t)),
    holdRefs, holdAgents, holdBooks, holdWitness,
  }

  // git update-ref -d refs/claims/<t> <expected>. The guard is the whole
  // safety argument: it refuses unless the ref still holds what was read.
  action reclaimDelete(a) = all {
    alive.get(a),
    pendTask.get(a) != "",
    refVal.get(pendTask.get(a)) == pendVal.get(a),
    refVal' = refVal.set(pendTask.get(a), 0),
    holder' = holder.set(pendTask.get(a), ""),
    deadline' = deadline.set(pendTask.get(a), 0),
    holdAgents,
    pendTask' = pendTask.set(a, ""),
    pendVal' = pendVal.set(a, 0),
    holdBooks,
    liveClaimDeleted' = (liveClaimDeleted or not(expired(pendTask.get(a)))),
    doubleWorked' = doubleWorked,
    reclaimedAfterCrash' = (reclaimedAfterCrash or
      not(alive.get(holder.get(pendTask.get(a))))),
  }

  // The holder renewed, or finished and somebody else took it, between the
  // read and the delete. Git refuses and the agent goes back to reading.
  action reclaimRefused(a) = all {
    alive.get(a),
    pendTask.get(a) != "",
    refVal.get(pendTask.get(a)) != pendVal.get(a),
    pendTask' = pendTask.set(a, ""),
    pendVal' = pendVal.set(a, 0),
    holdRefs, holdAgents, holdBooks, holdWitness,
  }

  // A renewal is a compare-and-swap to a NEW value, not a touch of something
  // beside the ref. That is what invalidates a stale reclaimer's expectation.
  action renew(a) = all {
    alive.get(a),
    working.get(a) != "",
    holder.get(working.get(a)) == a,
    refVal' = refVal.set(working.get(a), nextVal),
    holder' = holder,
    deadline' = deadline.set(working.get(a), clock + leaseLen),
    holdAgents, holdPend,
    finishCount' = finishCount, clock' = clock, nextVal' = nextVal + 1,
    holdWitness,
  }

  // Only the holder may finish. An agent whose claim was taken over finds
  // this guard false and has wasted its turn, which is the cost the lease buys.
  action finish(a) = all {
    alive.get(a),
    working.get(a) != "",
    holder.get(working.get(a)) == a,
    refVal' = refVal.set(working.get(a), 0),
    holder' = holder.set(working.get(a), ""),
    deadline' = deadline.set(working.get(a), 0),
    working' = working.set(a, ""),
    alive' = alive,
    holdPend,
    finishCount' = finishCount.set(working.get(a), finishCount.get(working.get(a)) + 1),
    clock' = clock, nextVal' = nextVal,
    holdWitness,
  }

  // The agent stops. Its claim stays behind with the deadline it had, which is
  // what makes the lease the recovery mechanism rather than a formality.
  action crash(a) = all {
    alive.get(a),
    working' = working.set(a, ""),
    alive' = alive.set(a, false),
    pendTask' = pendTask.set(a, ""),
    pendVal' = pendVal.set(a, 0),
    holdRefs, holdBooks, holdWitness,
  }

  action restart(a) = all {
    not(alive.get(a)),
    alive' = alive.set(a, true),
    working' = working,
    holdRefs, holdPend, holdBooks, holdWitness,
  }

  action tick = all {
    clock < maxClock,
    clock' = clock + 1,
    finishCount' = finishCount, nextVal' = nextVal,
    holdRefs, holdAgents, holdPend, holdWitness,
  }

  action step = nondet a = agents.oneOf() {
    nondet t = tasks.oneOf() {
      any {
        claimCreate(a, t),
        observeExpired(a, t),
        reclaimDelete(a),
        reclaimRefused(a),
        renew(a),
        finish(a),
        crash(a),
        restart(a),
        tick,
      }
    }
  }

  // A claim ref exists exactly when somebody holds it.
  val holderMatchesRef: bool =
    tasks.forall(t => (refVal.get(t) == 0) iff (holder.get(t) == ""))

  // ADR-023 keeps ADR-015's rule that a stage names a capability: nothing may
  // take work its role does not provide, whatever the race.
  val holderProvidesCapability: bool =
    tasks.forall(t =>
      holder.get(t) == "" or canDo(holder.get(t), needsOf.get(t)))

  // The safety property the whole design rests on. A takeover may only remove
  // a claim that has actually expired, never one whose holder renewed between
  // the read and the delete.
  val noLiveClaimDeleted: bool = not(liveClaimDeleted)

  // Only the holder may finish, so however many agents believe they are
  // working a task, one at most ever completes it. This is what the guard on
  // finish has to buy, and the reason a wasted turn is a cost rather than a
  // correctness failure.
  val noTaskFinishedTwice: bool = tasks.forall(t => finishCount.get(t) <= 1)

  val allInvariants: bool = and {
    holderMatchesRef,
    holderProvidesCapability,
    noLiveClaimDeleted,
    noTaskFinishedTwice,
  }

  // Witnesses, stated as negations so that a violation is the evidence.
  //
  // A hung holder stops renewing without stopping working, and a peer takes
  // its task while it is still alive. PRD-005 names this as an accepted risk,
  // and a model in which it could not happen would be modelling a design where
  // a lease is never taken from anyone.
  val neverDoubleWorked: bool = not(doubleWorked)

  // Recovery works: a crashed agent's task returns to the pool once its lease
  // lapses. A model where this never violates has a lease that never recovers
  // anything.
  val neverReclaimedAfterCrash: bool = not(reclaimedAfterCrash)

  // The cost of the lease, found by this model rather than reasoned about. An
  // agent whose claim lapsed keeps working a task a peer has since finished.
  // It cannot commit, because finish is guarded on holding the claim, but it
  // spends a whole turn before discovering that. Nothing in the design tells
  // it sooner, and the only cure is a holder that checks it still holds.
  val neverWorkedAfterLosingIt: bool =
    agents.forall(a =>
      working.get(a) == "" or finishCount.get(working.get(a)) == 0)
}
