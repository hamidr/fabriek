// Taking a task in the software factory, as decided in
// docs/ADR-024-a-take-is-a-claim-and-a-revalidation.md and required by phase 2
// of docs/PRD-005-agents-that-take-their-own-work.md.
//
// The design has no lock server. Several agents in separate cages share one
// git repository, and the only atomic thing between them is a ref update. An
// agent takes a task by creating refs/claims/<task> with an expected old value
// of "", which git refuses if the ref exists. The claim is a lease: it carries
// a deadline, the holder renews it while working, and an expired claim may be
// taken over by any capable agent.
//
// Two seams are checked here, and the second was added after a spike worked a
// task twice against real git and real git-bug.
//
// The first is the takeover. Creating a claim is one atomic step; taking over
// an expired one is two, a guarded delete and then a create, with an arbitrary
// interleaving in between. The modelled design therefore makes a renewal move
// the ref to a new value, so that an agent which observed an expired claim and
// then went to delete it is refused if the holder renewed in the meantime.
// Break that (make renew leave refVal alone) and noLiveClaimDeleted fails.
//
// The second is the take itself, and ADR-023's version of this model could not
// see it. That version guarded claimCreate on finishCount == 0, which asserts
// that reading the queue and compare-and-swapping the claim happen as one
// atomic step. They do not. An agent lists the takeable tasks, a peer takes,
// works, finishes and releases one of them, and the first agent's create-only
// compare-and-swap then succeeds precisely because the peer deleted the ref on
// its way out. The claim is granted for work that is already done.
//
// So the read and the swap are separate actions here, nothing prevents a task
// from being finished between them, and the design earns noTaskFinishedTwice
// by revalidating after the swap instead of by an assumption. Set
// revalidateAfterClaim to false and the invariant fails, which is what makes
// the guard load-bearing rather than decorative.
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

  // The decision under test. False models ADR-023's take, where winning the
  // compare-and-swap is the whole of taking a task.
  pure val revalidateAfterClaim: bool = true

  // refs/claims/<task>. Zero means the ref does not exist. Every claim and
  // every renewal takes a fresh value, which is what makes a guarded delete
  // able to tell a claim apart from its successor.
  var refVal: str -> int
  var holder: str -> str
  var deadline: str -> int

  var working: str -> str
  var alive: str -> bool

  // An agent that has read the queue and not yet swapped. This is the window
  // the spike fell into: what the queue said is already history by the time
  // the ref is written.
  var pendTake: str -> str

  // A claim this agent holds and has not yet started working. Revalidation
  // happens here, between the swap and the turn, which is the only place it
  // can happen and still be atomic with respect to the ref.
  var claimed: str -> str

  // An agent that has read an expired claim and not yet acted on it. This is
  // the read-then-act window the two-step takeover opens, and modelling it is
  // the point: without it a takeover looks atomic and nothing can go wrong.
  var pendTask: str -> str
  var pendVal: str -> int

  // How many times a task has been finished. A count rather than a set,
  // because "at most once" is the property the take has to deliver.
  var finishCount: str -> int
  var clock: int
  var nextVal: int

  // Witnesses. A guarded delete that removed a claim which had not expired, a
  // takeover that happened while another live agent still believed it was
  // working the task, a claim granted for work already finished, and that
  // claim being handed back instead of worked.
  var liveClaimDeleted: bool
  var doubleWorked: bool
  var reclaimedAfterCrash: bool
  var staleClaimTaken: bool
  var staleClaimAbandoned: bool

  def canDo(a: str, cap: str): bool = providesOf.get(a).contains(cap)
  def expired(t: str): bool = deadline.get(t) <= clock
  def idle(a: str): bool = and {
    working.get(a) == "",
    claimed.get(a) == "",
    pendTake.get(a) == "",
    pendTask.get(a) == "",
  }

  action holdRefs = all {
    refVal' = refVal, holder' = holder, deadline' = deadline,
  }
  action holdAgents = all { working' = working, alive' = alive }
  action holdTake = all { pendTake' = pendTake, claimed' = claimed }
  action holdPend = all { pendTask' = pendTask, pendVal' = pendVal }
  action holdBooks = all {
    finishCount' = finishCount, clock' = clock, nextVal' = nextVal,
  }
  action holdWitness = all {
    liveClaimDeleted' = liveClaimDeleted,
    doubleWorked' = doubleWorked,
    reclaimedAfterCrash' = reclaimedAfterCrash,
    staleClaimTaken' = staleClaimTaken,
    staleClaimAbandoned' = staleClaimAbandoned,
  }

  action init = all {
    refVal' = tasks.mapBy(_ => 0),
    holder' = tasks.mapBy(_ => ""),
    deadline' = tasks.mapBy(_ => 0),
    working' = agents.mapBy(_ => ""),
    alive' = agents.mapBy(_ => true),
    pendTake' = agents.mapBy(_ => ""),
    claimed' = agents.mapBy(_ => ""),
    pendTask' = agents.mapBy(_ => ""),
    pendVal' = agents.mapBy(_ => 0),
    finishCount' = tasks.mapBy(_ => 0),
    clock' = 0,
    nextVal' = 1,
    liveClaimDeleted' = false,
    doubleWorked' = false,
    reclaimedAfterCrash' = false,
    staleClaimTaken' = false,
    staleClaimAbandoned' = false,
  }

  // Reading the queue. The record says this task wants this capability and
  // carries no claim. Both facts are true when read and neither is held.
  action observeTakeable(a, t) = all {
    alive.get(a),
    idle(a),
    canDo(a, needsOf.get(t)),
    finishCount.get(t) == 0,
    refVal.get(t) == 0,
    pendTake' = pendTake.set(a, t),
    claimed' = claimed,
    holdRefs, holdAgents, holdPend, holdBooks, holdWitness,
  }

  // git update-ref refs/claims/<t> <new> "" succeeds only when the ref is
  // absent. Action atomicity is exactly the ref lock: the second agent to run
  // this finds refVal non-zero and its guard fails.
  //
  // There is deliberately no finishCount guard. The queue read that led here
  // is arbitrarily old, and a peer may have finished and released the task in
  // between, which is what leaves the ref absent for this swap to win.
  action claimCreate(a) = all {
    alive.get(a),
    pendTake.get(a) != "",
    refVal.get(pendTake.get(a)) == 0,
    refVal' = refVal.set(pendTake.get(a), nextVal),
    holder' = holder.set(pendTake.get(a), a),
    deadline' = deadline.set(pendTake.get(a), clock + leaseLen),
    pendTake' = pendTake.set(a, ""),
    claimed' = claimed.set(a, pendTake.get(a)),
    holdAgents, holdPend,
    finishCount' = finishCount, clock' = clock, nextVal' = nextVal + 1,
    liveClaimDeleted' = liveClaimDeleted,
    doubleWorked' = doubleWorked,
    reclaimedAfterCrash' = reclaimedAfterCrash,
    // The parentheses are load-bearing: x' = a or b parses as (x' = a) or b,
    // which is satisfiable without ever updating x and makes the witness lie.
    staleClaimTaken' = (staleClaimTaken or finishCount.get(pendTake.get(a)) > 0),
    staleClaimAbandoned' = staleClaimAbandoned,
  }

  // Somebody else got there first. The queue read is discarded rather than
  // retried against, because the loser has nothing to wait for.
  action claimRefused(a) = all {
    alive.get(a),
    pendTake.get(a) != "",
    refVal.get(pendTake.get(a)) != 0,
    pendTake' = pendTake.set(a, ""),
    claimed' = claimed,
    holdRefs, holdAgents, holdPend, holdBooks, holdWitness,
  }

  // The revalidation. Holding the claim, re-read the task: it must still want
  // this capability. Under revalidateAfterClaim the guard is real; without it
  // the agent starts work on whatever the swap happened to win.
  action adopt(a) = all {
    alive.get(a),
    claimed.get(a) != "",
    or {
      not(revalidateAfterClaim),
      finishCount.get(claimed.get(a)) == 0,
    },
    working' = working.set(a, claimed.get(a)),
    alive' = alive,
    pendTake' = pendTake,
    claimed' = claimed.set(a, ""),
    holdRefs, holdPend, holdBooks,
    liveClaimDeleted' = liveClaimDeleted,
    // Somebody else alive still thinks it is working this task. Reachable by
    // design, since a hung holder stops renewing without stopping working.
    doubleWorked' = (doubleWorked or
      agents.exists(b => b != a and alive.get(b) and
        working.get(b) == claimed.get(a))),
    reclaimedAfterCrash' = reclaimedAfterCrash,
    staleClaimTaken' = staleClaimTaken,
    staleClaimAbandoned' = staleClaimAbandoned,
  }

  // Revalidation refused it. The claim is handed straight back, which matters:
  // a claim dropped without deleting the ref would strand the task until the
  // lease lapsed, for work nobody is doing.
  action abandon(a) = all {
    alive.get(a),
    revalidateAfterClaim,
    claimed.get(a) != "",
    finishCount.get(claimed.get(a)) > 0,
    refVal' = refVal.set(claimed.get(a), 0),
    holder' = holder.set(claimed.get(a), ""),
    deadline' = deadline.set(claimed.get(a), 0),
    pendTake' = pendTake,
    claimed' = claimed.set(a, ""),
    holdAgents, holdPend, holdBooks,
    liveClaimDeleted' = liveClaimDeleted,
    doubleWorked' = doubleWorked,
    reclaimedAfterCrash' = reclaimedAfterCrash,
    staleClaimTaken' = staleClaimTaken,
    staleClaimAbandoned' = (staleClaimAbandoned or true),
  }

  // Reading an expired claim. Nothing is written yet, and what the agent
  // remembers is the value it saw, which is what it will pass to the delete.
  action observeExpired(a, t) = all {
    alive.get(a),
    idle(a),
    canDo(a, needsOf.get(t)),
    finishCount.get(t) == 0,
    refVal.get(t) != 0,
    expired(t),
    pendTask' = pendTask.set(a, t),
    pendVal' = pendVal.set(a, refVal.get(t)),
    holdRefs, holdAgents, holdTake, holdBooks, holdWitness,
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
    holdAgents, holdTake,
    pendTask' = pendTask.set(a, ""),
    pendVal' = pendVal.set(a, 0),
    holdBooks,
    liveClaimDeleted' = (liveClaimDeleted or not(expired(pendTask.get(a)))),
    doubleWorked' = doubleWorked,
    reclaimedAfterCrash' = (reclaimedAfterCrash or
      not(alive.get(holder.get(pendTask.get(a))))),
    staleClaimTaken' = staleClaimTaken,
    staleClaimAbandoned' = staleClaimAbandoned,
  }

  // The holder renewed, or finished and somebody else took it, between the
  // read and the delete. Git refuses and the agent goes back to reading.
  action reclaimRefused(a) = all {
    alive.get(a),
    pendTask.get(a) != "",
    refVal.get(pendTask.get(a)) != pendVal.get(a),
    pendTask' = pendTask.set(a, ""),
    pendVal' = pendVal.set(a, 0),
    holdRefs, holdAgents, holdTake, holdBooks, holdWitness,
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
    holdAgents, holdTake, holdPend,
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
    holdTake, holdPend,
    finishCount' = finishCount.set(working.get(a), finishCount.get(working.get(a)) + 1),
    clock' = clock, nextVal' = nextVal,
    holdWitness,
  }

  // The agent stops. Its claim stays behind with the deadline it had, which is
  // what makes the lease the recovery mechanism rather than a formality. A
  // claim it had taken but not yet adopted stays behind the same way.
  action crash(a) = all {
    alive.get(a),
    working' = working.set(a, ""),
    alive' = alive.set(a, false),
    pendTake' = pendTake.set(a, ""),
    claimed' = claimed.set(a, ""),
    pendTask' = pendTask.set(a, ""),
    pendVal' = pendVal.set(a, 0),
    holdRefs, holdBooks, holdWitness,
  }

  action restart(a) = all {
    not(alive.get(a)),
    alive' = alive.set(a, true),
    working' = working,
    holdRefs, holdTake, holdPend, holdBooks, holdWitness,
  }

  action tick = all {
    clock < maxClock,
    clock' = clock + 1,
    finishCount' = finishCount, nextVal' = nextVal,
    holdRefs, holdAgents, holdTake, holdPend, holdWitness,
  }

  action step = nondet a = agents.oneOf() {
    nondet t = tasks.oneOf() {
      any {
        observeTakeable(a, t),
        claimCreate(a),
        claimRefused(a),
        adopt(a),
        abandon(a),
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

  // A claim ref exists exactly when somebody holds it. Holding without
  // working is now a real state, between the swap and the revalidation.
  val holderMatchesRef: bool =
    tasks.forall(t => (refVal.get(t) == 0) iff (holder.get(t) == ""))

  // ADR-023 keeps ADR-015's rule that a stage names a capability: nothing may
  // take work its role does not provide, whatever the race.
  val holderProvidesCapability: bool =
    tasks.forall(t =>
      holder.get(t) == "" or canDo(holder.get(t), needsOf.get(t)))

  // The safety property the takeover rests on. A takeover may only remove a
  // claim that has actually expired, never one whose holder renewed between
  // the read and the delete.
  val noLiveClaimDeleted: bool = not(liveClaimDeleted)

  // The safety property the take rests on, and the one the spike broke. With
  // revalidateAfterClaim false this fails: two agents read one task as
  // takeable, the first finishes and releases it, and the second's create-only
  // swap wins against the absent ref and works it again.
  val noTaskFinishedTwice: bool = tasks.forall(t => finishCount.get(t) <= 1)

  // Nobody works a task that is already done. Stronger than the count, and it
  // is what the revalidation actually buys: the wasted turn never starts.
  val noWorkOnFinished: bool =
    agents.forall(a =>
      working.get(a) == "" or finishCount.get(working.get(a)) == 0)

  val allInvariants: bool = and {
    holderMatchesRef,
    holderProvidesCapability,
    noLiveClaimDeleted,
    noTaskFinishedTwice,
    noWorkOnFinished,
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

  // The race the spike found is reachable here. If this never violates, the
  // model has quietly made the queue read atomic with the swap again and the
  // revalidation is being checked against nothing.
  val neverStaleClaimTaken: bool = not(staleClaimTaken)

  // And the revalidation is what catches it. A run where this never violates
  // while neverStaleClaimTaken does would mean claims are granted for finished
  // work and never handed back.
  val neverStaleClaimAbandoned: bool = not(staleClaimAbandoned)
}
