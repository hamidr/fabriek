// The lifecycle of a factory on the host it is declared on, as decided in
// docs/ADR-067-fabriek-is-a-linux-host-program.md: no machine, a slice of
// service units per factory, and an `up` that starts the slice, clones the
// operator's checkout, renders a profile per role and prepares the forge
// and the bus before the executor may start a session. It replaces
// vm-lifecycle.qnt (ADR-019, ADR-057), whose boot became a unit start and
// whose disk became the factory's datasets.
//
// The states are absent, declared (rebuilt in, datasets made), started
// (the slice is up, nothing rendered), cloned, rendering, running (prepared
// for the pin `up` read) and stopping. Two sides interleave as before: `up`
// and `down` on one side, sessions writing the datasets on the other. One
// interleaving is new: `up` has two callers, the factory's unit at boot and
// a hand, and the two can run at once. They serialise on a lock per factory
// or they do not, and the model says which.
//
// Five properties carry over from vm-lifecycle.qnt: nothing fabriek does
// ends a factory mid-write, the datasets outlive everything but destroy, a
// session runs only inside a running factory, a session runs only on a
// profile rendered for the pin this `up` read, and running means every
// role has such a profile. One is new: two `up`s never render at once.
//
// What this model found (2026-09-21): with two callers and no lock, a
// hand's `up -u` moves the pin under the unit's `up`, renders one role for
// the new pin, and the unit then writes the prepared mark for the old pin
// it believes it rendered every role for: runningMeansEveryProfile fails in
// 60 steps. `up` takes a flock on the factory's state directory for its
// whole run (takeUp below), and moving the pin is done under it.
//
// ADR-070 (2026-09-25) puts each factory's roles in a nixcage machine of its
// own: a microVM that boots at `up` and holds the clone, the worktrees and
// every session. The machine is a variable of its own beside the factory's
// state, off, booting, ready or failed, because it can fail at any step
// without the factory's units knowing: a guest panics, qemu is killed, the
// OOM killer takes it. Clone and prepare run inside it and a session lives
// in it, so all three wait for ready, and a machine that fails ends every
// session in it at once. A seventh invariant: no session runs in a machine
// that is not ready.
module factoryLifecycle {
  // How many times the operator may move the pin. Bounds the state space;
  // six is enough to drift, restart and drift again with samples to spare.
  pure val maxPinGen = 6
  pure val roles = Set("backend", "reviewer")
  pure val callers = Set("unit", "hand")
  // How many times the machine may fail in one trace. Bounds the state
  // space as maxPinGen does, and keeps a failure that is enabled at almost
  // every step from ending nearly every trace before recovery is reached.
  pure val maxMachineFailures = 2

  var state: str
  var datasetsExist: bool
  // The factory's nixcage machine: off, booting, ready, failed.
  var machine: str

  // The pin on the host and the one the prepared mark was written for
  // (0: none).
  var pinGen: int
  var preparedGen: int

  // Per caller, the pin its `up` read when it started (0: not in `up`), and
  // the roles it has rendered so far. `up` renders each role and then
  // writes the mark; it does not look at the links again, so what it
  // believes it rendered is what the mark is written from.
  var inFlight: str -> int
  var renderedBy: str -> Set[str]

  // Which roles have a profile, and from which pin each was made. A
  // profile outlives a stop (it is a store path rooted under the state
  // directory), which is why it carries its generation.
  var profileGen: str -> int

  var sessions: Set[str]
  var writing: bool

  // Witnesses. The first must stay false; the others are states the design
  // has to be able to reach.
  var lostToAbruptHostStop: bool
  var staleReached: bool
  var halfRenderedReached: bool
  var secondCallerWaited: bool
  var machineFailedMidWrite: bool
  var machineFailures: int

  def up(s: str): bool =
    s == "started" or s == "cloned" or s == "rendering" or s == "running" or s == "stopping"

  action holdFactory = all {
    state' = state, datasetsExist' = datasetsExist, machine' = machine,
  }
  action holdGens = all {
    pinGen' = pinGen, preparedGen' = preparedGen, profileGen' = profileGen,
  }
  action holdUp = all { inFlight' = inFlight, renderedBy' = renderedBy }
  def holders: Set[str] = callers.filter(c => inFlight.get(c) > 0)
  def anyUp: bool = holders.size() > 0
  action holdGuest = all { sessions' = sessions, writing' = writing }
  action holdWitness = all {
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = staleReached,
    halfRenderedReached' = halfRenderedReached,
    secondCallerWaited' = secondCallerWaited,
    machineFailedMidWrite' = machineFailedMidWrite,
    machineFailures' = machineFailures,
  }

  action init = all {
    state' = "absent",
    datasetsExist' = false,
    machine' = "off",
    pinGen' = 1,
    preparedGen' = 0,
    inFlight' = callers.mapBy(_ => 0),
    renderedBy' = callers.mapBy(_ => Set()),
    profileGen' = roles.mapBy(_ => 0),
    sessions' = Set(),
    writing' = false,
    lostToAbruptHostStop' = false,
    staleReached' = false,
    halfRenderedReached' = false,
    secondCallerWaited' = false,
    machineFailedMidWrite' = false,
    machineFailures' = 0,
  }

  // nixos-rebuild with the factory in services.fabriek: the units exist and
  // the first `up` will find or make the datasets.
  action declare = all {
    state == "absent",
    state' = "declared",
    datasetsExist' = true, machine' = machine,
    holdGens, holdUp, holdGuest, holdWitness,
  }

  // A caller takes `up`'s lock. It reads the pin as of now; everything it
  // renders is for that pin. A second caller finding the lock held waits,
  // which is the witness secondCallerWaited.
  action takeUp = all {
    state == "declared" or state == "started" or state == "cloned",
    not(anyUp),
    nondet c = callers.oneOf()
    all {
      inFlight' = inFlight.set(c, pinGen),
      renderedBy' = renderedBy.set(c, Set()),
    },
    holdFactory, holdGens, holdGuest, holdWitness,
  }

  action secondCallerWaits = all {
    anyUp,
    holdFactory, holdGens, holdUp, holdGuest,
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = staleReached,
    halfRenderedReached' = halfRenderedReached,
    secondCallerWaited' = true,
    machineFailedMidWrite' = machineFailedMidWrite,
    machineFailures' = machineFailures,
  }

  // systemctl start of the slice. The prepared mark is per start: nothing
  // of last start's counts until render and prepare end.
  action start = all {
    state == "declared",
    anyUp,
    datasetsExist,
    state' = "started",
    datasetsExist' = datasetsExist, machine' = machine,
    pinGen' = pinGen, preparedGen' = 0, profileGen' = profileGen,
    holdUp, holdGuest, holdWitness,
  }

  action release(c: str): bool = all {
    inFlight' = inFlight.set(c, 0),
    renderedBy' = renderedBy.set(c, Set()),
  }

  // A unit fails to start. The datasets are untouched and the lock is
  // released, which is what makes retrying safe.
  action startFailed = all {
    state == "declared",
    nondet c = holders.oneOf()
    release(c),
    holdFactory, holdGens, holdGuest, holdWitness,
  }

  action clone = all {
    state == "started",
    anyUp,
    machine == "ready",
    state' = "cloned",
    datasetsExist' = datasetsExist, machine' = machine,
    holdGens, holdUp, holdGuest, holdWitness,
  }

  // The checkout is not where the declaration says, or the pin is not in
  // it. The slice stays up and unprepared; `up` reports and releases.
  action cloneFailed = all {
    state == "started",
    nondet c = holders.oneOf()
    release(c),
    holdFactory, holdGens, holdGuest, holdWitness,
  }

  action render = all {
    state == "cloned",
    anyUp,
    state' = "rendering",
    datasetsExist' = datasetsExist, machine' = machine,
    holdGens, holdUp, holdGuest, holdWitness,
  }

  // One role's profile realised for the pin this `up` read. A profile made
  // for the same pin is found in the store and kept: render is idempotent,
  // so this is a no-op on a role already done.
  action renderRole = all {
    state == "rendering",
    nondet c = holders.oneOf()
    nondet r = roles.oneOf()
    all {
      profileGen' = profileGen.set(r, inFlight.get(c)),
      renderedBy' = renderedBy.set(c, renderedBy.get(c).union(Set(r))),
      inFlight' = inFlight,
      pinGen' = pinGen, preparedGen' = preparedGen,
    },
    holdFactory, holdGuest, holdWitness,
  }

  // Render fails between two roles: a devShell that does not substitute, a
  // declaration the schema refuses. The slice stays up and unprepared with
  // whatever profiles it made kept, `up` reports and releases.
  action renderFailed = all {
    state == "rendering",
    nondet c = holders.oneOf()
    all {
      release(c),
      halfRenderedReached' = (halfRenderedReached or
        (roles.exists(r => profileGen.get(r) == inFlight.get(c)) and
         roles.exists(r => profileGen.get(r) != inFlight.get(c)))),
    },
    state' = "cloned",
    datasetsExist' = datasetsExist, machine' = machine,
    holdGens, holdGuest,
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = staleReached,
    secondCallerWaited' = secondCallerWaited,
    machineFailedMidWrite' = machineFailedMidWrite,
    machineFailures' = machineFailures,
  }

  // Every role has a profile for this `up`'s pin: prepare writes the mark,
  // the executor may start, and the lock is released.
  action prepared = all {
    state == "rendering",
    machine == "ready",
    nondet c = holders.oneOf()
    all {
      renderedBy.get(c) == roles,
      preparedGen' = inFlight.get(c),
      release(c),
    },
    state' = "running",
    datasetsExist' = datasetsExist, machine' = machine,
    pinGen' = pinGen, profileGen' = profileGen,
    holdGuest, holdWitness,
  }

  // The executor starts a role's session: only once prepared, and only for
  // a role whose profile link exists.
  action startSession = all {
    state == "running",
    machine == "ready",
    nondet r = roles.oneOf()
    all {
      not(sessions.contains(r)),
      profileGen.get(r) == preparedGen,
      sessions' = sessions.union(Set(r)),
    },
    writing' = writing,
    holdFactory, holdGens, holdUp, holdWitness,
  }

  action beginWrite = all {
    state == "running",
    machine == "ready",
    sessions.size() > 0,
    not(writing),
    writing' = true,
    sessions' = sessions,
    holdFactory, holdGens, holdUp, holdWitness,
  }

  action endWrite = all {
    writing,
    writing' = false,
    sessions' = sessions,
    holdFactory, holdGens, holdUp, holdWitness,
  }

  action endSession = all {
    sessions.size() > 0,
    not(writing),
    nondet r = sessions.oneOf()
    sessions' = sessions.exclude(Set(r)),
    writing' = false,
    holdFactory, holdGens, holdUp, holdWitness,
  }

  // fabriek down. Refused while an `up` holds the lock.
  action requestStop = all {
    state == "running" or state == "cloned" or state == "started",
    not(anyUp),
    state' = "stopping",
    datasetsExist' = datasetsExist, machine' = machine,
    holdGens, holdUp, holdGuest, holdWitness,
  }

  // The stop cannot complete because a session is still busy. Reported,
  // never forced: the factory goes back to running.
  action stopBlocked = all {
    state == "stopping",
    sessions.size() > 0 or writing,
    state' = "running",
    datasetsExist' = datasetsExist, machine' = machine,
    holdGens, holdUp, holdGuest, holdWitness,
  }

  action stopComplete = all {
    state == "stopping",
    sessions.size() == 0,
    not(writing),
    state' = "declared",
    datasetsExist' = datasetsExist, machine' = "off",
    holdGens, holdUp, holdGuest, holdWitness,
  }

  // The host loses power. Not something fabriek does; the residual risk
  // ADR-017 puts ZFS underneath. The lock is a flock and dies with the
  // process that held it.
  action abruptHostStop = all {
    up(state),
    state' = "declared",
    datasetsExist' = datasetsExist, machine' = "off",
    holdGens,
    inFlight' = callers.mapBy(_ => 0),
    renderedBy' = callers.mapBy(_ => Set()),
    sessions' = Set(),
    writing' = false,
    lostToAbruptHostStop' = (lostToAbruptHostStop or writing),
    staleReached' = staleReached,
    halfRenderedReached' = halfRenderedReached,
    secondCallerWaited' = secondCallerWaited,
    machineFailedMidWrite' = machineFailedMidWrite,
    machineFailures' = machineFailures,
  }

  // fabriek up -u: the pin moves on the host. A factory running on the old
  // one is stale until `up` renders again. Moving the pin is the first thing
  // `up -u` does and it does it under the lock, so an `up` in flight never
  // sees it move; a hand that wants the pin moved waits like any caller.
  action updatePin = all {
    not(anyUp),
    pinGen < maxPinGen,
    pinGen' = pinGen + 1,
    preparedGen' = preparedGen, profileGen' = profileGen,
    holdFactory, holdUp, holdGuest,
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = (staleReached or (state == "running" and preparedGen < pinGen + 1)),
    halfRenderedReached' = halfRenderedReached,
    secondCallerWaited' = secondCallerWaited,
    machineFailedMidWrite' = machineFailedMidWrite,
    machineFailures' = machineFailures,
  }

  // An `up` on a running factory: re-render for the current pin. The units
  // stay up, the clone is fetched, the profiles are made again (idempotent
  // for an unchanged pin) and the mark is rewritten.
  action reUp = all {
    state == "running",
    not(anyUp),
    sessions.size() == 0,
    nondet c = callers.oneOf()
    all {
      inFlight' = inFlight.set(c, pinGen),
      renderedBy' = renderedBy.set(c, Set()),
    },
    state' = "cloned",
    datasetsExist' = datasetsExist, machine' = machine,
    pinGen' = pinGen, preparedGen' = 0, profileGen' = profileGen,
    holdGuest, holdWitness,
  }

  // The operator removes the factory from services.fabriek and its
  // datasets by hand. Only once stopped.
  action destroy = all {
    state == "declared",
    not(anyUp),
    sessions.size() == 0,
    state' = "absent",
    datasetsExist' = false, machine' = machine,
    pinGen' = pinGen, preparedGen' = 0,
    profileGen' = roles.mapBy(_ => 0),
    holdUp, holdGuest, holdWitness,
  }

  // up boots the factory's machine once the slice is up, and again after
  // one failed; `machine up` on one already booting or ready is a no-op.
  action machineUp = all {
    up(state),
    state != "stopping",
    anyUp,
    machine == "off" or machine == "failed",
    machine' = "booting",
    state' = state, datasetsExist' = datasetsExist,
    holdGens, holdUp, holdGuest, holdWitness,
  }

  action machineReady = all {
    machine == "booting",
    machine' = "ready",
    state' = state, datasetsExist' = datasetsExist,
    holdGens, holdUp, holdGuest, holdWitness,
  }

  // The machine fails at any step: a panic, qemu killed, the host's OOM
  // killer. Every session in it ends with it; a write in flight is lost
  // inside the machine's disk, which is the boundary's price.
  action machineFails = all {
    machine == "booting" or machine == "ready",
    machineFailures < maxMachineFailures,
    machine' = "failed",
    sessions' = Set(),
    writing' = false,
    state' = state, datasetsExist' = datasetsExist,
    holdGens, holdUp,
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = staleReached,
    halfRenderedReached' = halfRenderedReached,
    secondCallerWaited' = secondCallerWaited,
    machineFailedMidWrite' = (machineFailedMidWrite or writing),
    machineFailures' = machineFailures + 1,
  }

  action step = any {
    machineUp, machineReady, machineFails,
    declare, takeUp, secondCallerWaits, start, startFailed,
    clone, cloneFailed, render, renderRole, renderFailed, prepared,
    startSession, beginWrite, endWrite, endSession,
    requestStop, stopBlocked, stopComplete,
    abruptHostStop, updatePin, reUp, destroy,
  }

  // A session exists only inside a factory that is running or stopping.
  val noSessionOutsideARunningFactory: bool =
    sessions.size() == 0 or (state == "running" or state == "stopping")

  // Nothing is ever up without the storage its state lives on.
  val noServiceWithoutItsDatasets: bool = not(up(state)) or datasetsExist

  // The datasets outlive every transition except the one that exists to
  // remove them: a failed start, a failed render, a stop, a host death.
  val datasetsOutliveEverythingButDestroy: bool =
    state == "absent" or datasetsExist

  // A role's session runs on a profile made for the pin the prepared mark
  // was written for, never on an older one, and never before prepare
  // finished for this start.
  val sessionOnlyOnThePreparedProfile: bool =
    sessions.forall(r => profileGen.get(r) == preparedGen and preparedGen > 0)

  // A running factory has every role's profile for its own pin: the mark
  // means what it says.
  val runningMeansEveryProfile: bool =
    state != "running" or roles.forall(r => profileGen.get(r) == preparedGen)

  // Two `up`s never run at once: the lock is what makes what a caller
  // rendered and what the links hold the same thing when the mark is
  // written.
  val oneUpAtATime: bool = holders.size() <= 1

  // For reaching witnesses only, never for checking invariants: the same
  // actions, with the pin moving and the machine failing only once the
  // factory is running. Under `step` both are enabled from the first
  // state, and a random walk spends maxPinGen and maxMachineFailures long
  // before it reaches running, so the witnesses that need them there go
  // unreached in millions of traces. Every state this reaches, `step`
  // reaches, so a witness found here is one the full model has.
  action witnessStep = any {
    machineUp, machineReady,
    all { state == "running", machineFails },
    declare, takeUp, secondCallerWaits, start, startFailed,
    clone, cloneFailed, render, renderRole, renderFailed, prepared,
    startSession, beginWrite, endWrite, endSession,
    requestStop, stopBlocked, stopComplete,
    abruptHostStop,
    all { state == "running", updatePin },
    reUp, destroy,
  }

  // Narrower still, for the witnesses of recovery: no stop, no failed
  // start, clone or render and no host death, which otherwise end most
  // traces before a stale or failed factory is brought back.
  action recoveryStep = any {
    machineUp, machineReady,
    all { state == "running", machineFails },
    declare, takeUp, start, clone, render, renderRole, prepared,
    startSession, beginWrite, endWrite, endSession,
    all { state == "running", updatePin },
    reUp,
  }

  // No session runs in a machine that is not ready: none is started in
  // one booting or failed, and a machine that fails takes its sessions.
  val noSessionInAMachineNotReady: bool =
    sessions.size() == 0 or machine == "ready"

  // A factory that is stopped or absent has its machine off.
  val stoppedMeansMachineOff: bool =
    not(state == "declared" or state == "absent") or machine == "off" or anyUp

  val allInvariants: bool = and {
    noSessionInAMachineNotReady,
    stoppedMeansMachineOff,
    noSessionOutsideARunningFactory,
    noServiceWithoutItsDatasets,
    datasetsOutliveEverythingButDestroy,
    sessionOnlyOnThePreparedProfile,
    runningMeansEveryProfile,
    oneUpAtATime,
  }

  // Witness, stated as a negation so a violation is the evidence: the pin
  // can move ahead of the factory running on it.
  val neverStale: bool = not(staleReached)

  // Witness: a stale factory becomes current again by `up` rendering for
  // the new pin, without a stop.
  val neverCurrentAgainAfterStale: bool =
    not(staleReached and state == "running" and preparedGen == pinGen)

  // Witness: render can stop halfway, with some profiles for this pin and
  // some not. If this never violates, the idempotence claim is untested.
  val neverHalfRendered: bool = not(halfRenderedReached)

  // Witness: a factory half rendered and then rendered again reaches
  // running with every profile.
  val neverRecoveredFromHalf: bool =
    not(halfRenderedReached and state == "running")

  // Witness: the boot unit and a hand did contend for `up`.
  val neverSecondCallerWaited: bool = not(secondCallerWaited)

  // Witness: a machine can fail under a write, which is what ADR-070 gives
  // up to have a kernel boundary.
  val neverMachineFailedMidWrite: bool = not(machineFailedMidWrite)

  // Witness: a factory recovers from its machine failing, by up.
  val neverRecoveredFromMachineFailure: bool =
    not(machineFailedMidWrite and machine == "ready" and state == "running" and sessions.size() > 0)

  // Witness: the one way left to end a factory mid-write is the host dying.
  val neverLostToAbruptHostStop: bool = not(lostToAbruptHostStop)
}
